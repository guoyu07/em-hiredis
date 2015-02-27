require 'uri'

module EventMachine::Hiredis
  # Manages EventMachine connections in order to provide reconnections.
  #
  # Emits the following events
  # - :connected - on successful connection or reconnection
  # - :reconnected - on successful reconnection
  # - :disconnected - no longer connected, when previously in connected state
  # - :reconnect_failed(failure_number) - a reconnect attempt failed
  #     This event is passed number of failures so far (1,2,3...)
  class ConnectionManager
    include EventEmitter

    TRANSITIONS = [
      # first connect call
      [ :initial, :connecting ],
      # TCP connect, or initialisation commands fail
      [ :connecting, :disconnected ],
      # Connection ready for use by clients
      [ :connecting, :connected ],
      # connection lost
      [ :connected, :disconnected ],
      # attempting automatic reconnect
      [ :disconnected, :connecting ],
      # all automatic reconnection attempts failed
      [ :disconnected, :failed ],
      # manual call of reconnect after failure
      [ :failed, :connecting ],
    ]

    # connection_factory: an object which responds to `call` by returning a
    #   deferrable which succeeds with a connected and initialised instance
    #   of EMConnection or fails if the connection was unsuccessful.
    #   Failures will be retried
    def initialize(connection_factory, em = EM)
      @em = em
      @connection_factory = connection_factory

      @reconnect_attempt = 0

      @sm = StateMachine.new
      TRANSITIONS.each { |t| @sm.transition(*t) }

      @sm.on(:connecting, &method(:on_connecting))
      @sm.on(:connected, &method(:on_connected))
      @sm.on(:disconnected, &method(:on_disconnected))
      @sm.on(:failed, &method(:on_failed))
    end

    def connect
      @sm.update_state(:connecting)
    end

    def reconnect
      case @sm.state
      when :initial
        connect
      when :connecting
        @cancel_connect.call
      when :connected
        @connection.close_connection
      when :disconnected
        @sm.update_state(:connecting)
      when :failed
        @sm.update_state(:connecting)
      end
    end

    def state
      @sm.state
    end

    # Access to the underlying connection. Care must be taken to ensure that the
    # `state` is :connected before this is used.
    def connection
      @connection
    end

    protected

    def on_connecting(prev_state)
      if @reconnect_timer
        @em.cancel_timer(@reconnect_timer)
        @reconnect_timer = nil
      end

      connection_success = lambda { |connection|
        @connection = connection
        @sm.update_state(:connected)

        connection.on(:disconnected) {
          @sm.update_state(:disconnected) if @connection == connection
        }
      }

      connection_failure = lambda { |e|
        @sm.update_state(:disconnected)
      }

      connection_df = @connection_factory.call
        .callback(&connection_success)
        .errback(&connection_failure)

      @cancel_connect = lambda {
        connection_df.cancel_callback(connection_success)
        connection_df.callback { |connection|
          connection.close_connection
          on_connecting(:connecting)
        }

        connection_df.cancel_errback(connection_failure)
        connection_df.errback {
          on_connecting(:connecting)
        }
      }
    end

    def on_connected(prev_state)
      emit(:connected)
      if @reconnect_attempt > 0
        emit(:reconnected)
        @reconnect_attempt = 0
      end
    end

    def on_failed(prev_state)
      emit(:failed)
    end

    def on_disconnected(prev_state)
      @connection = nil

      delay = case prev_state
      when :connected
        emit(:disconnected)
        :immediate
      when :connecting
        :delayed
      end

      emit(:reconnect_failed, @reconnect_attempt) if @reconnect_attempt > 0

      # External agents have the opportunity to call reconnect and change the
      # state when we emit :disconnected and :reconnected, so we should only
      # proceed here if our state has not been touched.
      return unless @sm.state == :disconnected

      if @reconnect_attempt > 3
        @sm.update_state(:failed)
      else
        @reconnect_attempt += 1
        if delay == :delayed
          @reconnect_timer = @em.add_timer(EventMachine::Hiredis.reconnect_timeout) {
            @sm.update_state(:connecting)
          }
        elsif delay == :immediate
          @sm.update_state(:connecting)
        else
          raise "Unrecognised delay specifier #{delay}"
        end
      end
    end
  end
end
