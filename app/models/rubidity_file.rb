class RubidityFile
  extend Memoist

  attr_accessor :filename
  
  class << self
    def registry
      return @registry if @registry
    
      @registry = {}.with_indifferent_access
      add_to_registry(Dir.glob(Rails.root.join("app/models/contracts/*.rubidity")))
    
      @registry
    end
    
    def add_to_registry(files)
      if files.is_a?(String) && File.directory?(files)
        files = Dir.glob(File.join(files, "*.rubidity"))
      end
      
      Array.wrap(files).each do |file|
        file = Rails.root.join(file) unless File.exist?(file)
        obj = new(file)
        registry[obj.ast_hash] ||= obj.contract_classes
      end
      
      registry
    end
  end
  
  def initialize(filename)
    @filename = filename
  end
  
  def file_ast
    ImportResolver.process(absolute_path)
  end
  memoize :file_ast
  
  def absolute_path
    if filename.start_with?("./")
      base_dir = File.dirname(filename)
      File.join(base_dir, filename[2..])
    else
      filename
    end
  end
  memoize :absolute_path
  
  def file_source
    Unparser.unparse(file_ast)
  end
  memoize :file_source
  
  def ast_hash
    Digest::SHA256.hexdigest(file_ast.to_sexp).first(32)
  end
  memoize :ast_hash
  
  def contract_asts
    file_ast.children.select do |node|
      next unless node.type == :block
      
      first_child = node.children.first
    
      first_child.type == :send && first_child.children.second == :contract
    end
  end
  memoize :contract_asts
  
  def contract_asts_and_sources
    contract_asts.map do |ast|
      OpenStruct.new({
        ast: ast,
        source: Unparser.unparse(ast)
      })
    end
  end
  memoize :contract_asts_and_sources

  def contract_names
    contract_asts.map do |node|
      node.children.first.children.third.children.first
    end
  end
  memoize :contract_names
  
  def contract_classes
    unless contract_names == contract_names.uniq
      raise "Duplicate contract names in #{filename}: #{contract_names}"
    end
    
    available_contracts = {}.with_indifferent_access
    
    contract_asts_and_sources.map do |obj|
      builder = ContractBuilder::Builder.new(available_contracts)

      copy = builder.instance_eval(obj.source)
      
      new_ast = ContractReplacer.process(copy.linearized_parents.map(&:name), obj.ast)
      new_source = Unparser.unparse(new_ast)
      
      line_number = new_ast.loc.line

      new_klass = builder.instance_eval(new_source, normalized_filename, line_number)
      
      new_klass.instance_variable_set(:@source_code, new_source)
      new_klass.instance_variable_set(:@file_source_code, file_source)
      
      if new_klass.name + ".rubidity" == normalized_filename
        new_klass.instance_variable_set(:@is_main_contract, true)
      end
      
      available_contracts[new_klass.name] = new_klass

      new_klass
    end
  end
  memoize :contract_classes

  def normalized_filename
    filename.split("/").last.sub(/\.rubidity$/, "") + ".rubidity"
  end
end