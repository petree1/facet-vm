class ContractBuilder < BasicObject
  def self.build_contract_class(
    available_contracts:,
    source:,
    filename:,
    line_number: 1
  )
    builder = new(available_contracts, source, filename, line_number)
    new_class = builder.instance_eval_with_isolation
    
    new_class.tap do |contract_class|
      ast = ::Unparser.parse(source)
      creation_code = ast.inspect
      init_code_hash = ::Digest::Keccak256.hexdigest(creation_code)
      
      contract_class.instance_variable_set(:@source_code, source)
      contract_class.instance_variable_set(:@creation_code, creation_code)
      contract_class.instance_variable_set(:@init_code_hash, init_code_hash)
    end
  end

  def instance_eval_with_isolation
    instance_eval(@source, @filename, @line_number).tap do
      remove_instance_variable(:@source)
      remove_instance_variable(:@filename)
      remove_instance_variable(:@line_number)
      remove_instance_variable(:@available_contracts)
    end
  end
  
  def remove_instance_variable(var)
    ::Object.instance_method(:remove_instance_variable).bind(self).call(var)
  end
  
  def initialize(available_contracts, source, filename, line_number)
    @available_contracts = available_contracts
    @source = source
    @filename = filename.to_s
    @line_number = line_number
  end
  
  def pragma(...)
  end
  
  def contract(name, is: [], abstract: false, upgradeable: false, &block)
    available_contracts = @available_contracts
    
    implementation_klass = ::Class.new(::ContractImplementation) do
      @parent_contracts = []
      
      ::Array.wrap(is).each do |dep|
        unless parent = available_contracts[dep]
          raise "Dependency #{dep} is not available."
        end
        
        @parent_contracts << parent
      end
      
      @is_upgradeable = upgradeable
      @is_abstract_contract = abstract
      @name = name.to_s
      @available_contracts = available_contracts.merge(@name => self)
      
      define_singleton_method(:evaluate_block, &block)
      evaluate_block
      singleton_class.remove_method(:evaluate_block)
    end
  end
end
