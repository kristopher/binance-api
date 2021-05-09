require 'openssl'
require 'logger'
require 'active_support/all'
require 'faraday'
require 'faraday_middleware'
require 'active_attr'
require 'money'

# https://github.com/binance-us/binance-official-api-docs/blob/master/rest-api.md

module Binance
  class Error < Exception; end

  COINS = [
    'ADA',
    'ALGO',
    'ATOM',
    'BAND',
    'BAT',
    'BCH',
    'BNB',
    'BTC',
    'BUSD',
    'COMP',
    'DAI',
    'DASH',
    'DOGE',
    'EGLD',
    'ENJ',
    'EOS',
    'ETC',
    'ETH',
    'HBAR',
    'HNT',
    'ICX',
    'IOTA',
    'KNC',
    'LINK',
    'LTC',
    'MANA',
    'MATIC',
    'MKR',
    'NANO',
    'NEO',
    'OMG',
    'ONE',
    'ONT',
    'OXT',
    'PAXG',
    'QTUM',
    'REP',
    'RVN',
    'SOL',
    'STORJ',
    'UNI',
    'USDC',
    'USDT',
    'VET',
    'VTHO',
    'WAVES',
    'XLM',
    'XTZ',
    'ZEC',
    'ZEN',
    'ZIL',
    'ZRX',
  ]

  extend self

  def config
    Thread.current[:binance_config] ||= options.deep_dup
  end

  def config=(options)
    Thread.current[:binance_config] = options.deep_dup
  end

  def client(options=nil)
    Thread.current[:binance_client] ||= Client.new(options || config)
  end

  def client=(c)
    Thread.current[:binance_client] = c
  end

  def api
    ::Binance::API
  end
  class Logger < ::Logger; end

  class Client
    attr_accessor :api_key
    attr_accessor :secret_key
    attr_accessor :timeout
    attr_accessor :options
    attr_accessor :url
    attr_accessor :log_level
    attr_accessor :logger

    def initialize(options)
      @api_key = options[:api_key]
      @secret_key = options[:secret_key]
      @timeout = options[:timeout] || default_timeout
      @url = options[:url]
      @log_level = options[:log_level] || default_log_level
      @logger = options[:logger] || default_logger
    end

    def default_timeout
      5
    end

    def default_log_level
      :info
    end

    def default_logger
      @default_logger ||= ::Binance::Logger.new($stdout)
    end

    def credentials
      @credentials ||=
        Credentials.new({
          api_key: api_key,
          secret_key: secret_key,
        })
    end

    def urls
      [
        'https://api.binance.us',
      ]
    end

    def url(reload=false)
      @url ||= nil if reload
      @url ||= urls.sample
    end

    def public_connection(reload=false)
      @public_connection = nil if reload
      @public_connection ||=
        Faraday.new({
          url: url,
          request: {
            timeout: timeout
          },
        }) do |conn|
          conn.request :url_encoded

          conn.response :json
          conn.response :logger, logger, { headers: log_level == :debug, bodies: log_level == :debug, log_level: log_level}

          conn.adapter Faraday.default_adapter
        end
    end

    def secure_connection(reload=false)
      @secure_connection = nil if reload
      @secure_connection ||=
        Faraday.new({
          url: url,
          headers: {
            'X-MBX-APIKEY' => credentials.api_key
          },
          request: {
            timeout: timeout
          }
        }) do |conn|
          conn.request :url_encoded
          conn.response :json

          conn.response :logger, logger, { headers: log_level == :debug, bodies: log_level == :debug, log_level: log_level}

          conn.adapter Faraday.default_adapter
        end
    end

    def signed_connection(reload=false)
      @signed_connection = nil if reload
      @signed_connection ||=
        Faraday.new({
          url: url,
          headers: {
            'X-MBX-APIKEY' => credentials.api_key
          },
          request: {
            timeout: timeout
          }
        }) do |conn|
          conn.request :url_encoded
          conn.request :signature

          conn.response :json
          conn.response :logger, logger, { headers: log_level == :debug, bodies: log_level == :debug, log_level: log_level}

          conn.adapter Faraday.default_adapter
        end
    end

  end

  class Credentials
    attr_accessor :api_key
    attr_accessor :secret_key

    def initialize(attrs={})
      attrs.each do |attr, value|
        send("#{attr}=", value)
      end
    end

    def api_key?
      api_key.present?
    end

    def secret_key?
      secret_key.present?
    end
  end

  class Request
    class Error < ::Binance::Error

      attr_accessor :response
      attr_accessor :request
      attr_accessor :error

      def initialize(request, response=nil, error=nil)
        @response = response
        @request = request
      end

      def status
        response&.status
      end

      def msg
        response&.error
      end

      def code
        response&.code
      end

      def request_method
        request.request_method
      end

      def request_path
        request.path
      end

      def message
        "[#{self}]#{"[#{status}]" if status}#{"[#{code}]" if code} #{request_method.to_s.upcase} #{request_path}#{" - #{msg}" if msg}"
      end
    end

    # HTTP 4XX return codes are used for malformed requests; the issue is on the sender's side.
    class MalformedRequestError < ::Binance::Request::Error; end
    class InternalServerError < ::Binance::Request::Error; end
    class TimeoutError < ::Binance::Request::Error; end

    class WAFLimitError < ::Binance::Request::Error
      # HTTP 403 return code is used when the WAF Limit (Web Application Firewall) has been violated.
      def status
        403
      end
    end

    class RateLimitExceededError < ::Binance::Request::Error
      # HTTP 429 return code is used when breaking a request rate limit.
      def status
        429
      end
    end

    class IPBannedError < ::Binance::Request::Error
      # HTTP 418 return code is used when an IP has been auto-banned for continuing to send requests after receiving 429 codes.
      def status
        418
      end
    end

    class ResponseReadTimeout < ::Binance::Request::Error
      # HTTP 504 When using /wapi/v3 the 504 code is used when the API successfully sent the message but not get a response within the timeout period. It is important to NOT treat this as a failure operation; the execution status is UNKNOWN and could have been a success.return code is used when the API successfully sent the message but not get a response within the timeout period. It is important to NOT treat this as a failure operation; the execution status is UNKNOWN and could have been a success.
      def status
        504
      end
    end

    extend ::Binance

    include ActiveAttr::Model

    METHODS = [
      :get,
      :post,
      :put,
      :delete,
    ]

    attribute :request_method
    attribute :path
    attribute :params, default: {}

    class << self
      attr_accessor :secure
      attr_accessor :signed

      def secure?
        !!@secure
      end

      def signed?
        !!@signed
      end

      def perform(options)
        new(options).perform
      end
    end

    def client
      ::Binance.client
    end

    def secure?
      self.class.secure?
    end

    def signed?
      self.class.signed?
    end

    def connection
      return client.signed_connection if signed?
      return client.secure_connection if secure?

      client.public_connection
    end

    def perform
      begin
        f_response = connection.send(request_method, path, params)
      rescue ::TimeoutError => e
        raise TimeoutError.new(self)
      rescue => e
        raise Error.new(self)
      end

      response = Response.new(f_response)
      if response.success?
        return response.body
      end

      case response.status
      when 403
        raise WAFLimitError.new(self, response)
      when 418
        raise IPBannedError.new(self, response)
      when 429
        raise RateLimitExceededError.new(self, response)
      when 504
        raise ResponseReadTimeout.new(self, response)
      else
        if response.status >= 400 && response.status < 500
          raise MalformedRequestError.new(self, response)
        end

        raise InternalServerError.new(self, response)
      end
    end
  end

  class PublicRequest < Request
    self.secure = false
    self.signed = false
  end

  class SecureRequest < Request
    self.secure = true
    self.signed = false
  end

  class SignedRequest < SecureRequest
    class SignatureMiddleware < ::Faraday::Middleware
      def signature(request_env)
        OpenSSL::HMAC.hexdigest("SHA256", ::Binance.client.credentials.secret_key, total_params(request_env))
      end

      def timestamp
        Time.now.to_i * 1000 # milliseconds
      end

      def total_params(request_env)
        request_env[:url].query.to_s + request_env[:body].to_s
      end

      def call(request_env)
        # NOTE Add the timestamp to the query before generating the signature
        request_env[:url].query = [request_env[:url].query, { timestamp: timestamp }.to_param].compact.join('&')

        request_env[:url].query = [request_env[:url].query, { signature: signature(request_env) }.to_param].compact.join('&')

        @app.call(request_env)
      end
    end
    Faraday::Request.register_middleware signature: -> { ::Binance::SignedRequest::SignatureMiddleware }

    self.secure = true
    self.signed = true
  end

  class Response
    attr_accessor :faraday

    def initialize(faraday)
      @faraday = faraday
    end

    def body
      @body ||= faraday.body
    end

    def code
      faraday.body['code']
    end

    def error
      faraday.body['msg']
    end

    def method_missing(method, *args)
      faraday.send(method, *args)
    end
  end

  module API
    extend self

    def status
      ::Binance::API::MarketData.exchange_info
    end

    def timezone
      ::Binance::API::MarketData.exchange_info.body['timezone']
    end

    def server_time
      Time.at(::Binance::API::MarketData.exchange_info.body['serverTime'] / 1000)
    end

    module Wallet
      extend self

      class << self

        ####################################################################################################################
        # Weight   1
        ####################################################################################################################
        # Name        Type   Mandatory Description
        ####################################################################################################################
        # recvWindow  LONG   NO
        ####################################################################################################################
        def coins(recv_window: nil)
          params = {}
          params[:recvWindow] = recv_window if recv_window

          SignedRequest.perform({
            request_method: :get,
            path: '/sapi/v1/capital/config/getall',
            params: params,
          })
        end

        ####################################################################################################################
        # Weight   1
        ####################################################################################################################
        # NAME       TYPE     REQUIRED  DESC
        ####################################################################################################################
        # type        STRING  YES       "SPOT", "MARGIN", "FUTURES"
        # startTime   LONG    NO
        # endTime     LONG    NO
        # limit       INT     NO        min 5, max 30, default 5
        # recvWindow  LONG    NO        Milliseconds
        ####################################################################################################################
        def snapshot(type:, start_time: nil, end_time: nil, recv_window: nil)
          params = {
            type: type,
          }
          params[:startTime] = start_time if start_time
          params[:endTime] = end_time if end_time
          params[:recvWindow] = recv_window if recv_window

          SignedRequest.perform({
            request_method: :get,
            path: '/api/v1/accountSnapshot',
            params: params,
          })
        end


        ####################################################################################################################
        # Weight   1
        ####################################################################################################################
        # NAME        TYPE    REQUIRED  DESC
        ####################################################################################################################
        # recvWindow  LONG    NO
        # timestamp   LONG    YES
        ####################################################################################################################
        # Fetch account status detail.
        ####################################################################################################################
        def account_status(recv_window: nil)
          timestamp =
            case timestamp
            when Time, ActiveSupport::TimeWithZone
              timestamp.to_i * 1000
            else
              timestamp
            end

          params = {
            timestamp: timestamp,
          }
          params[:recvWindow] = recv_window if recv_window

          SignedRequest.perform({
            request_method: :get,
            path: '/api/v1/account',
            params: params,
          })
        end
      end

      def wallet
        ::Binance::API::Wallet
      end
    end

    module MarketData
      extend self

      class << self
        ####################################################################################################################
        # Weight   1
        ####################################################################################################################
        # NOTE Test connectivity to the Rest API.
        ####################################################################################################################
        def ping
          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/ping',
          })
        end

        ####################################################################################################################
        # Weight   1
        ####################################################################################################################
        # NOTE Test connectivity to the Rest API and get the current server time.
        ####################################################################################################################
        def time
          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/time',
          })
        end

        ####################################################################################################################
        # Weight   1
        ####################################################################################################################
        # NOTE Current exchange trading rules and symbol information
        ####################################################################################################################
        def exchange_info
          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/exchangeInfo',
          })
        end

        ####################################################################################################################
        # Adjusted based on the limit:
        ####################################################################################################################
        # Limit                   Weight
        ####################################################################################################################
        # 5, 10, 20, 50, 100      1
        # 500                     5
        # 1000                    10
        # 5000                    50
        ####################################################################################################################
        # Name    Type    Mandatory   Description
        ####################################################################################################################
        # symbol  STRING  YES
        # limit   INT     NO          Default 100; max 5000. Valid limits:[5, 10, 20, 50, 100, 500, 1000, 5000]
        ####################################################################################################################
        def depth(symbol:, limit: nil)
          params = {
            symbol: symbol,
          }
          params[:limit] = limit if limit

          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/depth',
            params: params,
          })
        end

        ####################################################################################################################
        # Weight  1
        ####################################################################################################################
        # Name    Type    Mandatory   Description
        ####################################################################################################################
        # symbol  STRING  YES
        # limit   INT     NO          Default 500; max 1000.
        ####################################################################################################################
        def trades(symbol:, limit: nil)
          params = {
            symbol: symbol,
          }
          params[:limit] = limit if limit
          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/trades',
            params: params,
          })
        end

        ####################################################################################################################
        # Weight   5
        ####################################################################################################################
        # Name     Type    Mandatory   Description
        ####################################################################################################################
        # symbol   STRING  YES
        # limit    INT     NO          Default 500; max 1000.
        # fromId   LONG    NO          Trade id to fetch from. Default gets most recent trades.
        ####################################################################################################################
        def historical_trades(symbol:, from_id: nil, limit: nil)
          params = {
            symbol: symbol,
          }
          params[:fromId] = from_id if from_id
          params[:limit] = limit if limit

          SecureRequest.perform({
            request_method: :get,
            path: '/api/v3/historicalTrades',
            params: params,
          })
        end

        ####################################################################################################################
        # Weight   1
        ##########################################################################################
        # Name        Type     Mandatory     Description
        ##########################################################################################
        # symbol      STRING   YES
        # fromId      LONG     NO            id to get aggregate trades from INCLUSIVE.
        # startTime   LONG     NO            Timestamp in ms to get aggregate trades from INCLUSIVE.
        # endTime     LONG     NO            Timestamp in ms to get aggregate trades until INCLUSIVE.
        # limit       INT      NO            Default 500; max 1000.
        ##########################################################################################
        def agg_trades(symbol:, from_id: nil, start_time: nil, end_time: nil, limit: nil)
          params = {
            symbol: symbol
          }
          params[:fromId] = from_id if from_id
          params[:startTime] = start_time if start_time
          params[:endTime] = end_time if end_time
          params[:limit] = limit if limit

          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/aggTrades',
            params: params,
          })
        end

        ####################################################################################################################
        # Weight      1
        ####################################################################################################################
        # Name        Type     Mandatory   Description
        ####################################################################################################################
        # symbol      STRING   YES
        # interval    ENUM     YES         1m, 3m, 5m, 15m, 30m ,1h, 2h, 4h, 6h, 8h, 12h, 1d, 3d, 1w, 1M
        # startTime   LONG     NO
        # endTime     LONG     NO
        # limit       INT      NO          Default 500; max 1000.
        ####################################################################################################################
        def candlestick(symbol:, interval:, start_time: nil, end_time: nil, limit: nil)
          params = {
            symbol: symbol,
            interval: interval,
          }
          params[:startTime] = start_time if start_time
          params[:endTime] = end_time if end_time
          params[:limit] = limit if limit

          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/klines',
            params: params,
          })
        end

        alias_method :klines, :candlestick

        ####################################################################################################################
        # Weight
        ####################################################################################################################
        # 1 for a single symbol
        # 2 when the symbol parameter is omitted
        ####################################################################################################################
        # Name    Type    Mandatory Description
        ####################################################################################################################
        # symbol  STRING  NO
        ####################################################################################################################
        # NOTE If the symbol is not sent, prices for all symbols will be returned in an array.
        ####################################################################################################################
        def price(symbol:)
          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/ticker/price',
            params: {
              symbol: symbol,
            },
          })
        end

        ####################################################################################################################
        # Weight
        ####################################################################################################################
        # 1 for a single symbol
        # 2 when the symbol parameter is omitted
        ####################################################################################################################
        # Name    Type    Mandatory Description
        ####################################################################################################################
        # symbol  STRING  NO
        ####################################################################################################################
        # NOTE If the symbol is not sent, bookTickers for all symbols will be returned in an array.
        ####################################################################################################################
        def book_ticker(symbol:)
          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/ticker/bookTicker',
            params: {
              symbol: symbol,
            },
          })
        end

        ####################################################################################################################
        # Weight  1
        ####################################################################################################################
        # Name    Type    Mandatory   Description
        ####################################################################################################################
        # symbol  STRING  YES
        ####################################################################################################################
        def avg_price(symbol:)
          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/avgPrice',
            params: {
              symbol: symbol,
            },
          })
        end

        ####################################################################################################################
        # Weight
        # 1 for a single symbol
        # 40 when the symbol parameter is omitted
        ####################################################################################################################
        # Name    Type    Mandatory   Description
        ####################################################################################################################
        # symbol  STRING  YES
        ####################################################################################################################
        # NOTE If the symbol is not sent, tickers for all symbols will be returned in an array.
        ####################################################################################################################
        def avg_price_24h(symbol:)
          params = {
            symbol: symbol
          }
          PublicRequest.perform({
            request_method: :get,
            path: '/api/v3/ticker/24hr',
            params: params,
          })
        end
      end

      def market_data
        ::Binance::API::MarketData
      end
    end

    module SpotAccount
      extend self

      class << self

        #########################################################################################################################################################
        # Weight   1
        #########################################################################################################################################################
        # Name              Type      Mandatory    Description
        #########################################################################################################################################################
        # symbol            STRING    YES
        # side              ENUM      YES          BUY, SELL
        # type              ENUM      YES          MARKET, LIMIT, ETC
        # timeInForce       ENUM      NO           GTC, IOC, FOK
        # quantity          DECIMAL   NO
        # quoteOrderQty     DECIMAL   NO
        # price             DECIMAL   NO
        # newClientOrderId  STRING    NO           A unique id among open orders. Automatically generated if not sent.
        # stopPrice         DECIMAL   NO           Used with STOP_LOSS, STOP_LOSS_LIMIT, TAKE_PROFIT, and TAKE_PROFIT_LIMIT orders.
        # icebergQty        DECIMAL   NO           Used with LIMIT, STOP_LOSS_LIMIT, and TAKE_PROFIT_LIMIT to create an iceberg order.
        # newOrderRespType  ENUM      NO           Set the response JSON. ACK, RESULT, or FULL; MARKET and LIMIT order types default to FULL, all other orders default to ACK.
        # recvWindow        LONG      NO
        #########################################################################################################################################################
        # Additional mandatory parameters based on type:
        #########################################################################################################################################################
        # LIMIT             timeInForce, quantity, price
        # MARKET            quantity or quoteOrderQty
        # STOP_LOSS         quantity, stopPrice
        # STOP_LOSS_LIMIT   timeInForce, quantity, price, stopPrice
        # TAKE_PROFIT       quantity, stopPrice
        # TAKE_PROFIT_LIMIT timeInForce, quantity, price, stopPrice
        # LIMIT_MAKER       quantity, price
        #########################################################################################################################################################
        # Send in a new order.
        #########################################################################################################################################################
        def create_order(symbol:, side:, type:, time_in_force: nil, quantity: nil, quote_order_qty: nil, price: nil, new_client_order_id: nil, stop_price: nil, iceberg_qty: nil, new_order_response_type: nil)
          params = {
            symbol: symbol,
            side: side,
            type: type,
          }
          params[:timeInForce] = time_in_force if time_in_force
          params[:quantity] = quantity if quantity
          params[:quoteOrderQty] = quote_order_qty if quote_order_qty
          params[:price] = price if price
          params[:newClientOrderId] = new_client_order_id if new_client_order_id
          params[:stopPrice] = stop_price if stop_price
          params[:icebergQty] = iceberg_qty if iceberg_qty
          params[:newOrderRespType] = new_order_response_type if new_order_response_type

          SignedRequest.perform({
            request_method: :post,
            path: '/api/v3/order',
            params: params,
          })
        end

        #########################################################################################################################################################
        # Weight   1
        #########################################################################################################################################################
        # Name              Type     Mandatory   Description
        #########################################################################################################################################################
        # symbol            STRING   YES
        # orderId           LONG     NO
        # origClientOrderId STRING   NO
        # newClientOrderId  STRING   NO          Used to uniquely identify this cancel. Automatically generated by default.
        # recvWindow        LONG     NO          The value cannot be greater than 60000
        #########################################################################################################################################################
        # Cancel an active order.
        #########################################################################################################################################################
        # NOTE Either orderId or origClientOrderId must be sent.
        #########################################################################################################################################################
        def cancel_order(symbol:, order_id: nil, orig_client_order_id: nil, new_client_order_id: nil, recv_window: nil)
          params = {
            symbol: symbol
          }
          params[:orderId] = order_id if order_id
          params[:origClientOrderId] = orig_client_order_id if orig_client_order_id
          params[:newClientOrderId] = new_client_order_id if new_client_order_id
          params[:recvWindow] = recv_window if recv_window

          SignedRequest.perform({
            request_method: :delete,
            path: '/api/v3/order',
            params: params,
          })
        end

        #########################################################################################################################################################
        # Weight   1
        #########################################################################################################################################################
        # Name              Type     Mandatory   Description
        #########################################################################################################################################################
        # symbol            STRING   YES
        # recvWindow        LONG     NO          The value cannot be greater than 60000
        #########################################################################################################################################################
        # Cancels all active orders on a symbol.
        #########################################################################################################################################################
        # NOTE This includes OCO orders.
        #########################################################################################################################################################
        def cancel_all_orders(symbol:, recv_window: nil)
          params = {
            symbol: symbol,
          }
          params[:recvWindow] = recv_window if recv_window

          SignedRequest.perform({
            request_method: :delete,
            path: '/api/v3/openOrders',
            params: params,
          })
        end

        #########################################################################################################################################################
        # Weight   1
        #########################################################################################################################################################
        # Name              Type     Mandatory   Description
        #########################################################################################################################################################
        # symbol            STRING   YES
        # orderId           LONG     NO
        # origClientOrderId STRING   NO
        # newClientOrderId  STRING   NO          Used to uniquely identify this cancel. Automatically generated by default.
        # recvWindow        LONG     NO          The value cannot be greater than 60000
        #########################################################################################################################################################
        # Check an order's status.
        #########################################################################################################################################################
        # NOTE
        # Either orderId or origClientOrderId must be sent.
        # For some historical orders cummulativeQuoteQty will be < 0, meaning the data is not available at this time.
        #########################################################################################################################################################
        def get_order(symbol:, order_id: nil, orig_client_order_id: nil, new_client_order_id: nil, recv_window: nil)
          params = {
            symbol: symbol
          }
          params[:orderId] = order_id if order_id
          params[:origClientOrderId] = orig_client_order_id if orig_client_order_id
          params[:newClientOrderId] = new_client_order_id if new_client_order_id
          params[:recvWindow] = recv_window if recv_window

          SignedRequest.perform({
            request_method: :get,
            path: '/api/v3/order',
            params: params,
          })
        end

        #########################################################################################################################################################
        # Weight
        # 1 for a single symbol
        # 40 when the symbol parameter is omitted
        #########################################################################################################################################################
        # Name              Type     Mandatory   Description
        #########################################################################################################################################################
        # symbol            STRING   NO
        # recvWindow        LONG     NO          The value cannot be greater than 60000
        #########################################################################################################################################################
        # Get all open orders on a symbol
        #########################################################################################################################################################
        # NOTE
        # Careful when accessing this with no symbol.
        # If the symbol is not sent, orders for all symbols will be returned in an array.
        #########################################################################################################################################################
        def current_orders(symbol: nil, recv_window: nil)
          params = {}
          params[:symbol] = symbol if symbol
          params[:recvWindow] = recv_window if recv_window

          SignedRequest.perform({
            request_method: :get,
            path: '/api/v3/openOrders',
            params: params
          })
        end

        #########################################################################################################################################################
        # Weight   5
        #########################################################################################################################################################
        # Name              Type     Mandatory   Description
        #########################################################################################################################################################
        # symbol            STRING   YES
        # orderId           LONG     NO
        # startTime         LONG     NO
        # endTime           LONG     NO
        # limit             INT      NO          Default 500; max 1000.
        # recvWindow        LONG     NO          The value cannot be greater than 60000
        #########################################################################################################################################################
        # Get all account orders; active, canceled, or filled.
        #########################################################################################################################################################
        # NOTE
        # If orderId is set, it will get orders >= that orderId. Otherwise most recent orders are returned.
        # For some historical orders cummulativeQuoteQty will be < 0, meaning the data is not available at this time.
        # If startTime and/or endTime provided, orderId is not required.
        #########################################################################################################################################################
        def all_orders(symbol:, order_id: nil, start_time: nil, end_time: nil, limit: nil, recv_window: nil)
          params = {
            symbol: symbol,
          }
          params[:orderId] = order_id if order_id
          params[:startTime] = start_time if start_time
          params[:endTime] = end_time if end_time
          params[:limit] = limit if limit
          params[:recvWindow] = recv_window if recv_window

          SignedRequest.perform({
            request_method: :get,
            path: '/api/v3/allOrders',
            params: params,
          })
        end

        #########################################################################################################################################################
        # Weight   5
        #########################################################################################################################################################
        # Name              Type     Mandatory   Description
        #########################################################################################################################################################
        # recvWindow        LONG     NO          The value cannot be greater than 60000
        #########################################################################################################################################################
        # Get current account information.
        #########################################################################################################################################################
        def account_information(recv_window: nil)
          params = {}
          params[:recWindow] = recv_window if recv_window
          SignedRequest.perform({
            request_method: :get,
            path: '/api/v3/account',
            params: params,
          })
        end

        #########################################################################################################################################################
        # Weight   5
        #########################################################################################################################################################
        # Name              Type     Mandatory   Description
        #########################################################################################################################################################
        # symbol            STRING   YES
        # orderId           LONG     NO
        # startTime         LONG     NO
        # endTime           LONG     NO
        # limit             INT      NO          Default 500; max 1000.
        # recvWindow        LONG     NO          The value cannot be greater than 60000
        #########################################################################################################################################################
        # Get trades for a specific account and symbol.
        #########################################################################################################################################################
        # NOTE
        # If fromId is set, it will get id >= that fromId. Otherwise most recent trades are returned.
        #########################################################################################################################################################
        def trades_list(symbol:, start_time: nil, end_time: nil, from_id: nil, limit: nil, recv_window: nil)
          params = {
            symbol: symbol,
          }
          params[:startTime] = start_time if start_time
          params[:endTime] = end_time if end_time
          params[:fromId] = from_id if from_id
          params[:limit] = limit if limit
          params[:recWindow] = recv_window if recv_window

          SignedRequest.perform({
            request_method: :get,
            path: '/api/v3/myTrades',
            params: params,
          })
        end
      end

      def spot_account
        ::Binance::API::SpotAccount
      end
    end

    extend Wallet
    extend MarketData
    extend SpotAccount
  end

  module Wallet
    extend self

    class Coin
      include ActiveAttr::Model

      attribute :name, type: String
      attribute :symbol, type: String
      attribute :amount_satoshi
      attribute :withdrawing
      attribute :trading
      attribute :raw

      class << self
        def from_json(json)
          new({
            name: json['name'],
            symbol: json['coin'],
            amount: json['free'],
            withdrawing: json['withdrawing'],
            trading: json['trading'],
            raw: json
          })
        end
      end

      def amount=(value)
        value =
          case value
          when String
            value.to_f
          when Float
            value
          when Integer
            value.to_f
          end

        self.amount_satoshi = (value * 100_000_000).to_i
      end

      def amount
        amount_satoshi / 100_000_000.0
      end

      alias_method :name, :symbol
      alias_method :balance, :amount
    end

    def api
      ::Binance.api.wallet
    end

    def coins
      api.coins.map do |coin|
        if coin['free'].to_i > 0
          Coin.from_json(coin)
        end
      end.compact
    end
  end

  module MarketData
    extend self

    def api
      ::Binance.api.market_data
    end

    def price(symbol)
      api.price(symbol: symbol)['price'].to_f
    end

    def avg_price(symbol)
      api.avg_price(symbol: symbol)['price'].to_f
    end

    alias_method :average_price, :avg_price

    def avg_price_24h(symbol)
      api.avg_price_24h(symbol: symbol)['price'].to_f
    end

    alias_method :average_price_24h, :avg_price_24h

    COINS.each do |coin|
      const_set("#{coin}USD", Module.new do
        define_method(:price) do
          ::Binance::MarketData.price("#{coin}USD")
        end

        define_method(:avg_price) do
          ::Binance::MarketData.avg_price("#{coin}USD")
        end

        define_method(:book_ticker) do
          ::Binance::API::MarketData.book_ticker(symbol: "#{coin}USD")
        end

        define_method(:avg_price_24h) do
          ::Binance::MarketData.avg_price_24h("#{coin}USD")
        end

        extend self
      end)

      define_method("#{coin.downcase}_usd") do
        return "::Binance::MarketData::#{coin}USD".constantize
      end
    end
  end
end