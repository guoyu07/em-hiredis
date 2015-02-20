require 'spec_helper'
require 'support/inprocess_redis_mock'

describe EM::Hiredis::PubsubClient do
  default_timeout 4

  class PubsubTestConnection
    include EM::Hiredis::PubsubConnection
    include EM::Hiredis::MockConnection
  end

  class TestEM
    attr_reader :connections

    def initialize(expected_connections)
      @timers = Set.new
      @connections = []
      expected_connections.times { @connections << PubsubTestConnection.new }
      @connection_index = 0
    end

    def connect(host, port, connection_class, *args)
      connection = @connections[@connection_index]
      @connection_index += 1
      connection
    end

    def add_timer(delay, &blk)
      timer = Object.new
      @timers.add(timer)
      blk.call

      return timer
    end

    def cancel_timer(timer)
      marker = @timers.delete(timer)
      marker.should_not == nil
    end
  end

  # Create expected_connections connections, inject them in order in to the
  # client as it creates new ones
  def mock_connections(expected_connections, uri = 'redis://localhost:6379')
    em = TestEM.new(expected_connections)

    yield EM::Hiredis::PubsubClient.new(uri, nil, nil, em), em.connections

    em.connections.each { |c| c._expectations_met! }
  end

  it "should unsubscribe all callbacks for a channel on unsubscribe" do
    mock_connections(1) do |client, (connection)|
      client.connect
      connection.connection_completed

      connection._expect_and_echo('subscribe channel')
      connection._expect_and_echo('unsubscribe channel')

      # Block subscription
      df_block = client.subscribe('channel') { |m| fail }
      # Proc example
      df_proc = client.subscribe('channel', Proc.new { |m| fail })

      df_block.callback {
        df_proc.callback {
          client.unsubscribe('channel').callback {
            connection.emit(:message, 'channel', 'hello')
          }
        }
      }
    end
  end

  it "should allow selective unsubscription" do
    mock_connections(1) do |client, (connection)|
      client.connect
      connection.connection_completed
      connection._expect_and_echo('subscribe channel')

      received_messages = 0

      # Block subscription
      df_block = client.subscribe('channel') { |m| received_messages += 1 } # block
      # Proc example
      proc = Proc.new { |m| fail }
      df_proc = client.subscribe('channel', proc)

      df_block.callback {
        df_proc.callback {
          client.unsubscribe_proc('channel', proc).callback {
            connection.emit(:message, 'channel', 'hello')
          }
        }
      }

      received_messages.should == 1
    end
  end

  it "should unsubscribe from redis when all subscriptions for a channel are unsubscribed" do
    mock_connections(1) do |client, (connection)|
      client.connect
      connection.connection_completed
      connection._expect_and_echo('subscribe channel')
      connection._expect_and_echo('unsubscribe channel')

      proc_a = Proc.new { |m| fail }
      df_a = client.subscribe('channel', proc_a)
      proc_b = Proc.new { |m| fail }
      df_b = client.subscribe('channel', proc_b)

      df_a.callback {
        df_b.callback {
          client.unsubscribe_proc('channel', proc_a).callback {
            client.unsubscribe_proc('channel', proc_b).callback {
              connection.emit(:message, 'channel', 'hello')
            }
          }
        }
      }
    end
  end

  it "should punsubscribe all callbacks for a pattern on punsubscribe" do
    mock_connections(1) do |client, (connection)|
      client.connect
      connection.connection_completed

      connection._expect_and_echo('psubscribe channel:*')
      connection._expect_and_echo('punsubscribe channel:*')

      # Block subscription
      df_block = client.psubscribe('channel:*') { |m| fail }
      # Proc example
      df_proc = client.psubscribe('channel:*', Proc.new { |m| fail })

      df_block.callback {
        df_proc.callback {
          client.punsubscribe('channel:*').callback {
            connection.emit(:pmessage, 'channel:*', 'channel:hello', 'hello')
          }
        }
      }
    end
  end

  it "should allow selective punsubscription" do
    mock_connections(1) do |client, (connection)|
      client.connect
      connection.connection_completed
      connection._expect_and_echo('psubscribe channel:*')

      received_messages = 0

      # Block subscription
      df_block = client.psubscribe('channel:*') { |m| received_messages += 1 } # block
      # Proc example
      proc = Proc.new { |m| fail }
      df_proc = client.psubscribe('channel:*', proc)

      df_block.callback {
        df_proc.callback {
          client.punsubscribe_proc('channel:*', proc).callback {
            connection.emit(:pmessage, 'channel:*', 'channel:hello', 'hello')
          }
        }
      }

      received_messages.should == 1
    end
  end

  it "should punsubscribe from redis when all psubscriptions for a pattern are punsubscribed" do
    mock_connections(1) do |client, (connection)|
      client.connect
      connection.connection_completed
      connection._expect_and_echo('psubscribe channel:*')
      connection._expect_and_echo('punsubscribe channel:*')

      proc_a = Proc.new { |m| fail }
      df_a = client.psubscribe('channel:*', proc_a)
      proc_b = Proc.new { |m| fail }
      df_b = client.psubscribe('channel:*', proc_b)

      df_a.callback {
        df_b.callback {
          client.punsubscribe_proc('channel:*', proc_a).callback {
            client.punsubscribe_proc('channel:*', proc_b).callback {
              connection.emit(:pmessage, 'channel:*', 'channel:hello', 'hello')
            }
          }
        }
      }
    end
  end

  it 'should auth if password provided' do
    mock_connections(1, 'redis://:mypass@localhost:6379') do |client, (connection)|
      connection._expect_and_echo('auth mypass')

      connected = false
      client.connect.callback {
        connected = true
      }
      connection.connection_completed

      connected.should == true
    end
  end

end
