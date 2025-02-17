class ContractTransaction < ApplicationRecord
  include ContractErrors
  
  belongs_to :ethscription, primary_key: :transaction_hash, foreign_key: :transaction_hash, optional: true
  has_many :contract_states, foreign_key: :transaction_hash, primary_key: :transaction_hash
  has_many :contracts, foreign_key: :transaction_hash, primary_key: :transaction_hash
  has_many :contract_artifacts, foreign_key: :transaction_hash, primary_key: :transaction_hash
  
  has_one :transaction_receipt, foreign_key: :transaction_hash, primary_key: :transaction_hash, inverse_of: :contract_transaction
  has_many :contract_calls, foreign_key: :transaction_hash, primary_key: :transaction_hash, inverse_of: :contract_transaction
  
  attr_accessor :tx_origin, :payload
  
  def self.transaction_mimetype
    "application/vnd.facet.tx+json"
  end
  
  def ethscription=(ethscription)
    assign_attributes(
      block_blockhash: ethscription.block_blockhash,
      block_timestamp: ethscription.block_timestamp,
      block_number: ethscription.block_number,
      transaction_index: ethscription.transaction_index,
      tx_origin: ethscription.creator
    )
    
    begin
      self.payload = OpenStruct.new(JSON.parse(ethscription.content))
    rescue JSON::ParserError, NoMethodError => e
      raise InvalidEthscriptionError.new("JSON parse error: #{e.message}")
    end
    
    validate_payload!
    
    super(ethscription)
  end
  
  def validate_payload!
    unless BlockContext.start_block_passed?
      raise InvalidEthscriptionError.new("Start block not passed")
    end
    
    unless payload.present? && payload.data&.is_a?(Hash)
      raise InvalidEthscriptionError.new("Payload not present")
    end
    
    op = payload.op&.to_sym
    data_keys = payload.data.keys.map(&:to_sym).to_set

    unless [:create, :call, :static_call].include?(op)
      raise InvalidEthscriptionError.new("Invalid op: #{op}")
    end
    
    if op == :create
      unless [
        [:init_code_hash].to_set,
        [:init_code_hash, :args].to_set,
        
        [:init_code_hash, :source_code].to_set,
        [:init_code_hash, :source_code, :args].to_set
      ].include?(data_keys)
        raise InvalidEthscriptionError.new("Invalid data keys: #{data_keys}")
      end
    end
    
    if [:call, :static_call].include?(op)
      unless [
        [:to, :function].to_set,
        [:to, :function, :args].to_set
      ].include?(data_keys)
        raise InvalidEthscriptionError.new("Invalid data keys: #{data_keys}")
      end
      
      unless payload.data['to'].to_s.match(/\A0x[a-f0-9]{40}\z/i)
        raise InvalidEthscriptionError.new("Invalid to address: #{payload.data['to']}")
      end
    end
  end
  
  def initial_call
    contract_calls.target.sort_by(&:internal_transaction_index).first
  end
  
  def transaction_receipt_for_import
    base_attrs = {
      transaction_hash: transaction_hash,
      block_number: block_number,
      block_blockhash: block_blockhash,
      transaction_index: transaction_index,
      block_timestamp: block_timestamp,
      logs: contract_calls.target.flat_map(&:logs).sort_by { |log| log['index'] }.map { |log| log.except('index') },
      status: status,
      runtime_ms: initial_call.calculated_runtime_ms,
      gas_price: ethscription.gas_price,
      gas_used: ethscription.gas_used,
      transaction_fee: ethscription.transaction_fee,
    }
    
    call_attrs = initial_call.attributes.with_indifferent_access.slice(
      :to_contract_address,
      :created_contract_address,
      :effective_contract_address,
      :call_type,
      :from_address,
      :function,
      :args,
      :return_value,
      :error
    )
    
    attrs = base_attrs.merge(call_attrs)
    
    TransactionReceipt.new(attrs)
  end
  
  def self.simulate_transaction(from:, tx_payload:)
    max_block_number = EthBlock.max_processed_block_number
    
    cache_key = [
      SystemConfigVersion.latest_tx_hash,
      max_block_number,
      from,
      tx_payload
    ].to_cache_key(:simulate_transaction)
    
    cache_key = Digest::SHA256.hexdigest(cache_key)
  
    Rails.cache.fetch(cache_key) do
      mimetype = ContractTransaction.transaction_mimetype
      uri = %{data:#{mimetype};rule=esip6,#{tx_payload.to_json}}
      
      current_block = EthBlock.new(
        block_number: max_block_number + 1,
        timestamp: Time.zone.now.to_i,
        blockhash: "0x" + SecureRandom.hex(32)
      )
      
      ethscription_attrs = {
        transaction_hash: "0x" + SecureRandom.hex(32),
        block_number: current_block.block_number,
        block_blockhash: current_block.blockhash,
        creator: from&.downcase,
        block_timestamp: current_block.timestamp,
        transaction_index: 1,
        content_uri: uri,
        initial_owner: Ethscription.required_initial_owner,
        mimetype: mimetype,
        processing_state: "pending"
      }
      
      eth = Ethscription.new(ethscription_attrs)
      
      BlockContext.set(
        system_config: SystemConfigVersion.current,
        current_block: current_block,
        contracts: [],
        contract_artifacts: [],
        ethscriptions: [eth]
      ) do
        BlockContext.process_contract_transactions(persist: false)
      end
      
      {
        transaction_receipt: eth.contract_transaction&.transaction_receipt_for_import,
        internal_transactions: eth.contract_transaction&.contract_calls&.map(&:as_json),
        ethscription_status: eth.processing_state,
        ethscription_error: eth.processing_error,
        ethscription_content_uri: uri
      }.with_indifferent_access
    end
  end
  
  def self.make_static_call(
    contract:,
    function_name:,
    function_args: {},
    msgSender: nil
  )
    simulate_transaction_result = simulate_transaction(
      from: msgSender,
      tx_payload: {
        op: :static_call,
        data: {
          function: function_name,
          args: function_args,
          to: contract
        }
      }
    )
  
    receipt = simulate_transaction_result[:transaction_receipt]
    
    if receipt.status != 'success'
      raise StaticCallError.new("Static Call error #{receipt.error}")
    end
    
    receipt.return_value
  end
  
  def with_global_context
    TransactionContext.set(
      call_stack: CallStack.new(TransactionContext),
      active_contracts: [],
      current_transaction: self,
      current_event_index: 0,
      tx_origin: tx_origin,
      tx_current_transaction_hash: transaction_hash,
      block_number: block_number,
      block_timestamp: block_timestamp,
      block_blockhash: block_blockhash,
      block_chainid: BlockContext.current_chainid,
      transaction_index: transaction_index
    ) do
      yield
    end
  end
  
  def make_initial_call
    payload_data = OpenStruct.new(payload.data)
      
    TransactionContext.call_stack.execute_in_new_frame(
      to_contract_init_code_hash: payload_data.init_code_hash,
      to_contract_source_code: payload_data.source_code,
      to_contract_address: payload_data.to&.downcase,
      function: payload_data.function,
      args: payload_data.args,
      type: payload.op.to_sym,
    )
  end
  
  def execute_transaction
    begin
      make_initial_call
    rescue ContractError, TransactionError
    end

    if success?
      TransactionContext.active_contracts.each(&:take_state_snapshot)
    end
  end
  
  def success?
    status == :success
  end
  
  def status
    failed = contract_calls.target.any? do |call|
      call.failure? && !call.in_low_level_call_context
    end
    
    failed ? :failure : :success
  end
end
