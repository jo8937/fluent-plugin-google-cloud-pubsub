# coding: utf-8
require 'fluent/plugin/google_cloud_pubsub/version'
require 'fluent/mixin/config_placeholders'

module Fluent
  class GoogleCloudPubSubOutput < BufferedOutput
    Fluent::Plugin.register_output('google_cloud_pubsub', self)

    config_set_default :buffer_type, 'memory'
    config_set_default :flush_interval, 1
    config_set_default :buffer_chunk_limit, 7m

    config_param :email, :string, default: nil
    config_param :private_key_path, :string, default: nil
    config_param :private_key_passphrase, :string, default: 'notasecret'
    config_param :project, :string
    config_param :topic, :string
    config_param :auto_create_topic, :bool, default: false
    config_param :request_timeout, :integer, default: 60

    unless method_defined?(:log)
      define_method("log") { $log }
    end

    def initialize
      super
      require 'base64'
      require 'json'
      require 'google/api_client'
    end

    def configure(conf)
      super
      raise Fluent::ConfigError, "'email' must be specifed" unless @email
      raise Fluent::ConfigError, "'private_key_path' must be specifed" unless @private_key_path
      raise Fluent::ConfigError, "'project' must be specifed" unless @project
      raise Fluent::ConfigError, "'topic' must be specifed" unless @topic
    end

    def client
      if @cached_client.nil?
        client = Google::APIClient.new(
          application_name: 'Fluentd plugin for Google Cloud Pub/Sub',
          application_version: Fluent::GoogleCloudPubSubPlugin::VERSION,
          faraday_option: { 'timeout' => @request_timeout }
        )

        key = Google::APIClient::KeyUtils.load_from_pkcs12(@private_key_path, @private_key_passphrase)

        client.authorization = Signet::OAuth2::Client.new(
          token_credential_uri: 'https://accounts.google.com/o/oauth2/token',
          audience: 'https://accounts.google.com/o/oauth2/token',
          scope: ['https://www.googleapis.com/auth/pubsub', 'https://www.googleapis.com/auth/cloud-platform'],
          issuer: @email,
          signing_key: key
        )

        client.authorization.fetch_access_token!

        @cached_client = client
      elsif @cached_client.expired?
        @cached_client.authorization.fetch_access_token!
      end

      @cached_client
    end

    def start
      super
      @cached_client = nil
      @pubsub = client().discovered_api('pubsub', 'v1beta2')
    end

    #def format_stream(tag, es)
    #  super
    #  buf = ''
    #  es.each do |time, record|
    #   buf << record.to_json unless record.empty?
    #  end
    #  buf
    #end

    def extract_response_obj(response_body)
      return nil unless response_obj =~ /^{/
      JSON.parse(response_obj)
    end

    def publish(rows)
      topic = "projects/#{@project}/topics/#{@topic}"

      messages = [{
        #attributes: {
        #  key: "value"
        #},
        data: Base64.encode64(rows.to_json)
      }]

      res = client().execute(
        api_method: pubsub.projects.topics.publish,
        parameters: {
          topic: topic
        },
        body_object: {
          messages: messages
        }
      )

      res_obj = extract_response_obj(res.body)
      if res.success?
        message = res_obj['messageIds'] || res.body
        log.info "DONE pubsub.projects.topics.publish", topic: topic, code: res.status, message: message
      else
        message = res_obj['error']['message'] || res.body
        log.error "pubsub.projects.topics.publish", topic: topic, code: res.status, message: message
        raise "Failed to publish into Google Cloud Pub/Sub"
      end
    end

    def write(chunk)
      rows = []
      chunk.each do |row|
        rows << row
      end
      publish(rows)
    end
  end
end
