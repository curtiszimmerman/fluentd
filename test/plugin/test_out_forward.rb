require_relative '../helper'
require 'fluent/test'
require 'fluent/plugin/out_forward'

class ForwardOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end

  TARGET_HOST = '127.0.0.1'
  TARGET_PORT = unused_port
  CONFIG = %[
    send_timeout 51
    <server>
      name test
      host #{TARGET_HOST}
      port #{TARGET_PORT}
    </server>
  ]

  TARGET_CONFIG = %[
    port #{TARGET_PORT}
    bind #{TARGET_HOST}
  ]

  def create_driver(conf=CONFIG)
    Fluent::Test::OutputTestDriver.new(Fluent::ForwardOutput) {
      attr_reader :responses, :exceptions

      def initialize
        super
        @responses = []
        @exceptions = []
      end

      def send_data(node, tag, chunk)
        # Original #send_data returns nil when it does not wait for responses or when on response timeout.
        @responses << super(node, tag, chunk)
      rescue => e
        @exceptions << e
        raise e
      end
    }.configure(conf)
  end

  def test_configure
    d = create_driver
    nodes = d.instance.nodes
    assert_equal 51, d.instance.send_timeout
    assert_equal :udp, d.instance.heartbeat_type
    assert_equal 1, nodes.length
    node = nodes.first
    assert_equal "test", node.name
    assert_equal '127.0.0.1', node.host
    assert_equal TARGET_PORT, node.port
  end

  def test_configure_tcp_heartbeat
    d = create_driver(CONFIG + "\nheartbeat_type tcp")
    assert_equal :tcp, d.instance.heartbeat_type
  end

  def test_phi_failure_detector
    d = create_driver(CONFIG + %[phi_failure_detector false \n phi_threshold 0])
    node = d.instance.nodes.first
    stub(node.failure).phi { raise 'Should not be called' }
    node.tick
    assert_equal node.available, true

    d = create_driver(CONFIG + %[phi_failure_detector true \n phi_threshold 0])
    node = d.instance.nodes.first
    node.tick
    assert_equal node.available, false
  end

  def test_wait_response_timeout_config
    d = create_driver(CONFIG)
    assert_equal false, d.instance.extend_internal_protocol
    assert_equal false, d.instance.require_ack_response
    assert_equal 190, d.instance.ack_response_timeout

    d = create_driver(CONFIG + %[
      require_ack_response true
      ack_response_timeout 2s
    ])
    assert d.instance.extend_internal_protocol
    assert d.instance.require_ack_response
    assert_equal 2, d.instance.ack_response_timeout
  end

  def test_events_forwarding_with_ack
    target_input_driver = create_target_input_driver()
    target_input_driver.expected_emits_length = 2
    target_input_driver.run_timeout = 3

    d = create_driver(CONFIG + %[flush_interval 0s])

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    d.register_run_post_condition do
      d.instance.responses.length > 0
    end

    target_input_driver.run do
      d.run do
        records.each do |record|
          d.emit record, time
        end
      end
    end

    emits = target_input_driver.emits
    assert_equal ['test', time, records[0]], emits[0]
    assert_equal ['test', time, records[1]], emits[1]

    assert_equal [nil], d.instance.responses # not attempt to receive responses, so nil is returned
    assert_empty d.instance.exceptions
  end

  def test_send_to_a_node_not_supporting_responses
    target_input_driver = create_target_input_driver(->(options){ nil })

    d = create_driver(CONFIG + %[flush_interval 1s])

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    d.register_run_post_condition do
      d.instance.responses.length == 1
    end

    target_input_driver.run do
      d.run do
        records.each do |record|
          d.emit record, time
        end
      end
    end

    emits = target_input_driver.emits
    assert_equal ['test', time, records[0]], emits[0]
    assert_equal ['test', time, records[1]], emits[1]

    assert_equal [nil], d.instance.responses # not attempt to receive responses, so nil is returned
    assert_empty d.instance.exceptions
  end

  def test_require_a_node_supporting_responses_to_respond_with_ack
    target_input_driver = create_target_input_driver()

    d = create_driver(CONFIG + %[
      flush_interval 1s
      require_ack_response true
      ack_response_timeout 1s
    ])

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    d.register_run_post_condition do
      d.instance.responses.length == 1
    end

    target_input_driver.run do
      d.run do
        records.each do |record|
          d.emit record, time
        end
      end
    end

    emits = target_input_driver.emits
    assert_equal ['test', time, records[0]], emits[0]
    assert_equal ['test', time, records[1]], emits[1]

    assert_equal 1, d.instance.responses.length
    assert d.instance.responses[0].has_key?('ack')
    assert_empty d.instance.exceptions
  end

  def test_require_a_node_not_supporting_responses_to_respond_with_ack
    target_input_driver = create_target_input_driver(->(options){ sleep 5 })
    target_input_driver.expected_emits_length = 2
    target_input_driver.run_timeout = 5

    d = create_driver(CONFIG + %[
      flush_interval 1s
      require_ack_response true
      ack_response_timeout 1s
    ])

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    d.register_run_post_condition do
      d.instance.responses.length == 1
    end

    target_input_driver.run do
      d.run do
        records.each do |record|
          d.emit record, time
        end
      end
    end

    emits = target_input_driver.emits
    assert_equal ['test', time, records[0]], emits[0]
    assert_equal ['test', time, records[1]], emits[1]

    node = d.instance.nodes.first
    assert_equal false, node.available # node is regarded as unavailable when timeout

    assert_empty d.instance.responses # send_data() raises exception, so response is missing
    assert_equal 1, d.instance.exceptions.size
  end

  def create_target_input_driver(response_stub=nil, conf=TARGET_CONFIG)
    require 'fluent/plugin/in_forward'

    Fluent::Test::Driver::Input.new(Fluent::Plugin::ForwardInput) {
      if response_stub.nil?
        # do nothing because in_forward responds for ack option in default
      else
        define_method(:response) do |options|
          return response_stub.(options)
        end
      end
    }.configure(conf)
  end
end
