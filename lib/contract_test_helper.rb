module ContractTestHelper
  def trigger_contract_interaction_and_expect_call_error(**params)
    trigger_contract_interaction_and_expect_status(status: "failure", **params)
  end
  
  def trigger_contract_interaction_and_expect_error(**params)
    trigger_contract_interaction_and_expect_status(status: "failure", **params)
  end
  
  def trigger_contract_interaction_and_expect_success(**params)
    trigger_contract_interaction_and_expect_status(status: "success", **params)
  end
  
  def trigger_contract_interaction_and_expect_deploy_error(**params)
    trigger_contract_interaction_and_expect_status(status: "failure", **params)
  end
  
  def trigger_contract_interaction_and_expect_status(status:, **params)
    transactions = params[:transactions] || [{ from: params[:from], payload: params.delete(:payload) || params.delete(:data) }]
    ethscriptions = ContractTestHelper.trigger_contract_interaction(
      transactions: transactions,
      **params.slice(:block_timestamp)
    )
    
    ethscriptions.each do |eth|
      receipt = eth&.contract_transaction&.transaction_receipt
  
      if !receipt
        expect(status).to eq("failure")
        return eth
      end
      
      expect(receipt.status).to eq(status), failure_message(receipt)
  
      if status == "failure" && params[:error_msg_includes]
        expect(receipt.error['message']).to include(params[:error_msg_includes])
      end
    end
  
    receipts = ethscriptions.map { |eth| eth.contract_transaction&.transaction_receipt }
    receipts.length == 1 ? receipts.first : receipts
  end
  
  def trigger_contract_interaction_and_expect_status2(transactions:, block_timestamp:)
    ethscriptions = ContractTestHelper.trigger_contract_interaction(
      transactions: transactions.map { |t| t.except(:expected_status, :error_msg_includes) },
      block_timestamp: block_timestamp
    )
  
    transactions.each_with_index do |transaction, index|
      eth = ethscriptions[index]
      receipt = eth&.contract_transaction&.transaction_receipt
  
      if !receipt || receipt.status != transaction[:expected_status]
        raise "Expected #{transaction[:expected_status]} but was #{receipt&.status || 'no receipt'}"
      end
  
      if transaction[:expected_status] == "failure" && transaction[:error_msg_includes]
        unless receipt.error['message'].include?(transaction[:error_msg_includes])
          raise "Expected error message to include #{transaction[:error_msg_includes]}"
        end
      end
    end
  end
  
  def chainid
    if ENV.fetch("ETHEREUM_NETWORK") == "eth-mainnet"
      1
    elsif ENV.fetch("ETHEREUM_NETWORK") == "eth-goerli"
      5
    elsif ENV.fetch("ETHEREUM_NETWORK") == "eth-sepolia"
      11155111
    else
      raise "Unknown network: #{ENV.fetch("ETHEREUM_NETWORK")}"
    end
  end
  
  def self.set_initial_admin_address
    block_timestamp = Time.current.to_i
    from = ENV.fetch("INITIAL_SYSTEM_CONFIG_ADMIN_ADDRESS")
    mimetype = SystemConfigVersion.system_mimetype

    existing = Ethscription.newest_first.first
    
    block = EthBlock.order(imported_at: :desc).first
    
    block_number = block&.block_number.to_i + 1
    transaction_index = existing&.transaction_index.to_i + 1
    
    blockhash = "0x" + SecureRandom.hex(32)
    
    EthBlock.create!(
      block_number: block_number,
      blockhash: blockhash,
      parent_blockhash: block&.blockhash || "0x" + SecureRandom.hex(32),
      timestamp: Time.zone.now.to_i,
      imported_at: Time.zone.now,
      processing_state: "complete",
      transaction_count: 0,
      runtime_ms: 0
    )
    
    payload = {
      op: "updateAdminAddress",
      data: "0xF2dEe376De4167b8570389e8386Ea11233da0ae2"
    }
    
    uri = %{data:#{mimetype};rule=esip6,#{payload.to_json}}
    tx_hash = "0x" + SecureRandom.hex(32)
    sha = Digest::SHA256.hexdigest(uri)
    
    ethscription_attrs = {
      "transaction_hash"=>tx_hash,
      "block_number"=> block_number,
      "block_blockhash"=> blockhash,
      "creator"=>from.downcase,
      block_timestamp: block_timestamp,
      "initial_owner"=> Ethscription.required_initial_owner,
      "transaction_index"=>transaction_index,
      "content_uri"=> uri,
      mimetype: mimetype,
      processing_state: :pending,
    }
    
    Ethscription.new(ethscription_attrs).process!(persist: true)
    
    uri
  end
  
  def self.set_initial_start_block
    block_timestamp = Time.current.to_i
    from = SystemConfigVersion.current_admin_address
    mimetype = SystemConfigVersion.system_mimetype

    existing = Ethscription.newest_first.first
    
    block = EthBlock.order(imported_at: :desc).first
    
    block_number = block&.block_number.to_i + 1
    transaction_index = existing&.transaction_index.to_i + 1
    
    blockhash = "0x" + SecureRandom.hex(32)
    
    EthBlock.create!(
      block_number: block_number,
      blockhash: blockhash,
      parent_blockhash: block&.blockhash || "0x" + SecureRandom.hex(32),
      timestamp: Time.zone.now.to_i,
      imported_at: Time.zone.now,
      processing_state: "complete",
      transaction_count: 0,
      runtime_ms: 0
    )
    
    payload = {
      op: "updateStartBlockNumber",
      data: block_number + 1
    }
    
    uri = %{data:#{mimetype};rule=esip6,#{payload.to_json}}
    tx_hash = "0x" + SecureRandom.hex(32)
    sha = Digest::SHA256.hexdigest(uri)
    
    ethscription_attrs = {
      "transaction_hash"=>tx_hash,
      "block_number"=> block_number,
      "block_blockhash"=> blockhash,
      "creator"=>from.downcase,
      block_timestamp: block_timestamp,
      "initial_owner"=>Ethscription.required_initial_owner,
      "transaction_index"=>transaction_index,
      "content_uri"=> uri,
      mimetype: mimetype,
      processing_state: 'pending'
    }
    
    Ethscription.new(ethscription_attrs).process!(persist: true)
    uri
  end
  
  def self.set_initial_supported_contracts
    new_names = [
      "BridgeAndCallHelper",
      "EtherBridge02",
      "FacetSwapV1Locker",
      "EditionMetadataRenderer01",
      "NFTCollection01",
      "FacetPortV101",
      "EtherBridge",
      "EthscriptionERC20Bridge03",
      "PublicMintERC20",
      "NameRegistry01",
      "FacetSwapV1Factory02",
      "FacetSwapV1Pair02",
      "FacetSwapV1Router03",
      "AirdropERC20",
    ]
    
    new_hashes = new_names.map do |name|
      item = RubidityTranspiler.transpile_and_get(name)
      item.init_code_hash
    end
    
    ContractTestHelper.update_supported_contracts(*new_hashes, replace: true)
  end
  
  def update_supported_contracts(*new_names)
    new_hashes = new_names.map do |name|
      item = RubidityTranspiler.transpile_and_get(name)
      item.init_code_hash
    end
    
    ContractTestHelper.update_supported_contracts(*new_hashes)
  end
  
  def failure_message(interaction)
    test_location = caller_locations.find { |location| location.path.include?('/spec/') }
    "\nCall error: #{interaction.error}\nTest failed at: #{test_location}"
  end
  
  def self.dep
    ContractTestHelper.set_initial_supported_contracts
    
    @creation_receipt = ContractTestHelper.trigger_contract_interaction(
      command: 'deploy',
      from: "0xC2172a6315c1D7f6855768F843c420EbB36eDa97",
      data: {
        "protocol": "PublicMintERC20",
        "constructorArgs": {
          "name": "My Fun Token",
          "symbol": "FUN",
          "maxSupply": "21000000",
          "perMintLimit": "1000",
          "decimals": 18
        },
      }
    )
  end
  
  def self.transform_old_format_to_new(payload)
    payload = payload.stringify_keys
    
    if payload.key?("protocol")
      return {data: {
        "type" => payload.delete("protocol"),
        "args" => payload.delete("constructorArgs")
      }}
    elsif payload.key?("contract")
      to = payload.delete("contract")
      data = {
        "function" => payload.delete("functionName"),
        "args" => payload.delete("args")
      }
      return { "to" => to, "data" => data }
    end
  
    payload
  end
  
  def self.update_supported_contracts(*new_hashes, replace: false)
    block_timestamp = Time.current.to_i
    from = SystemConfigVersion.current_admin_address
    mimetype = SystemConfigVersion.system_mimetype
    
    current_list = SystemConfigVersion.current.supported_contracts
    
    current_list = replace ? new_hashes : current_list + new_hashes
    
    payload = {
      op: "updateSupportedContracts",
      data: current_list.flatten
    }
    
    uri = %{data:#{mimetype};rule=esip6,#{payload.to_json}}
    
    tx_hash = "0x" + SecureRandom.hex(32)
    sha = Digest::SHA256.hexdigest(uri)
    
    existing = Ethscription.newest_first.first
    
    block = EthBlock.order(imported_at: :desc).first
    
    block_number = block&.block_number.to_i + 1
    transaction_index = existing&.transaction_index.to_i + 1
    
    blockhash = "0x" + SecureRandom.hex(32)
    
    EthBlock.create!(
      block_number: block_number,
      blockhash: blockhash,
      parent_blockhash: block&.blockhash || "0x" + SecureRandom.hex(32),
      timestamp: Time.zone.now.to_i,
      imported_at: Time.zone.now,
      processing_state: "complete",
      transaction_count: 0,
      runtime_ms: 0
    )
    
    ethscription_attrs = {
      "transaction_hash"=>tx_hash,
      "block_number"=> block_number,
      "block_blockhash"=> blockhash,
      "creator"=>from.downcase,
      block_timestamp: block_timestamp,
      "initial_owner"=> Ethscription.required_initial_owner,
      "transaction_index"=>transaction_index,
      "content_uri"=> uri,
      mimetype: mimetype,
      processing_state: :pending
    }
    
    eth = Ethscription.create!(ethscription_attrs)
    eth.process!(persist: true)
    
    uri
  end
  
  def self.trigger_contract_interaction(
    command: nil,
    from: nil,
    data: nil,
    payload: nil,
    transactions: [],
    block_timestamp: Time.current.to_i
  )
    use_old_api = transactions.blank?
    if use_old_api
      transactions = [{ from: from, payload: data || payload }]
    end
  
    block = nil
    
    ethscriptions = transactions.map.with_index do |transaction, index|
      from = transaction[:from]
      payload = transform_old_format_to_new(transaction[:payload]).with_indifferent_access
  
      if payload['data'] && payload['data']['type']
        item = RubidityTranspiler.transpile_and_get(payload['data'].delete('type'))
  
        payload['data']['source_code'] = item.source_code
        payload['data']['init_code_hash'] = item.init_code_hash
      end
  
      if !payload['op']
        if payload['to']
          payload = { 'op' => 'call' }.merge(payload)
          payload['data'] = { 'to' => payload.delete('to') }.merge(payload['data'])
        else
          payload.delete('to')
          payload = { 'op' => 'create' }.merge(payload)
        end
      end
  
      mimetype = ContractTransaction.transaction_mimetype
      uri = %{data:#{mimetype},#{payload.to_json}}
  
      tx_hash = "0x" + SecureRandom.hex(32)
      sha = Digest::SHA256.hexdigest(uri)
  
      existing = Ethscription.newest_first.first
  
      block = EthBlock.order(block_number: :desc).first
  
      block_number = block&.block_number.to_i + 1
      transaction_index = existing&.transaction_index.to_i + 1
  
      blockhash = "0x" + SecureRandom.hex(32)
  
      block = EthBlock.create!(
        block_number: block_number,
        blockhash: blockhash,
        parent_blockhash: block&.blockhash || "0x" + SecureRandom.hex(32),
        timestamp: block_timestamp.to_i,
        imported_at: Time.zone.now,
        processing_state: "complete",
        transaction_count: 1,
        runtime_ms: 0
      )
  
      ethscription_attrs = {
        "transaction_hash"=>tx_hash,
        "block_number"=> block_number,
        "block_blockhash"=> blockhash,
        "creator"=>from.downcase,
        block_timestamp: block_timestamp.to_i,
        "initial_owner"=> Ethscription.required_initial_owner,
        "transaction_index"=>transaction_index + index,
        "content_uri"=> uri,
        mimetype: mimetype,
        processing_state: :pending
      }
  
      Ethscription.create!(ethscription_attrs)
    end
  
    BlockContext.set(
      system_config: SystemConfigVersion.current,
      current_block: block,
      contracts: [],
      contract_artifacts: [],
      ethscriptions: ethscriptions
    ) do
      BlockContext.process!
    end
  
    use_old_api ? ethscriptions.first : ethscriptions
    ethscriptions
  end
  
  def in_block(block_timestamp: Time.current.to_i, &block)
    transactions = []
    proxy = Object.new
  
    # Define the method on the proxy object
    proxy.define_singleton_method(:trigger_contract_interaction_and_expect_success) do |from:, payload:|
      transactions << { from: from, payload: payload, expected_status: 'success' }
    end
  
    proxy.define_singleton_method(:trigger_contract_interaction_and_expect_error) do |from:, payload:|
      transactions << { from: from, payload: payload, expected_status: "failure" }
    end
  
    # Execute the block with the proxy object as the context
    block.call(proxy)
  
    # Now trigger all the interactions in the same block context
    unless transactions.empty?
      # Extract error_msg_includes if it's specifically set for any transaction
      trigger_contract_interaction_and_expect_status2(
        transactions: transactions,
        block_timestamp: block_timestamp
      )
    end
  end

  def self.test_api
    creation_receipt = ContractTestHelper.trigger_contract_interaction(
      command: 'deploy',
      from: "0xC2172a6315c1D7f6855768F843c420EbB36eDa97",
      data: {
        "protocol": "PublicMintERC20",
        "constructorArgs": {
          "name": "My Fun Token",
          "symbol": "FUN",
          "maxSupply": "21000000",
          "perMintLimit": 1000,
          "decimals": 18
        },
      }
    )
    
    mint_receipt = ContractTestHelper.trigger_contract_interaction(
      command: 'call',
      from: "0xC2172a6315c1D7f6855768F843c420EbB36eDa97",
      data: {
        "contract": creation_receipt.address,
        "functionName": "mint",
        "args": {
          "amount": 5
        },
      }
    )
    
    transfer_receipt = ContractTestHelper.trigger_contract_interaction(
      command: 'call',
      from: "0xC2172a6315c1D7f6855768F843c420EbB36eDa97",
      data: {
        "contract": creation_receipt.address,
        "functionName": "transfer",
        "args": {
          "to": "0xF99812028817Da95f5CF95fB29a2a7EAbfBCC27E",
          "amount": 2
        },
      }
    )
    
    ContractTestHelper.trigger_contract_interaction(
      command: 'call',
      from: "0xC2172a6315c1D7f6855768F843c420EbB36eDa97",
      data: {
        "contract": creation_receipt.address,
        "functionName": "approve",
        "args": {
          "spender": "0xF99812028817Da95f5CF95fB29a2a7EAbfBCC27E",
          "amount": "2"
        },
      }
    )
    
    return
    created_id = creation_receipt.address
    caller_hash = mint_receipt.eth_transaction_id
    sender_hash = transfer_receipt.eth_transaction_id
    
    args = {
      address: '0xC2172a6315c1D7f6855768F843c420EbB36eDa97'
    }.to_json
    args = CGI.escape(args)
    
    
    url = "http://localhost:3002/api/contracts/#{created_id}/static-call/balance_of?args=#{args}"
    
    url2 = "http://localhost:3002/api/contracts/call-receipts/#{caller_hash}"
    url2 = "http://localhost:3002/api/contracts/call-receipts/#{sender_hash}"
    
    return [url, url2]
  end
end
$cth = ContractTestHelper