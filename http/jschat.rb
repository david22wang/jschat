require 'rubygems'
require 'sinatra'
require 'sha1'
require 'eventmachine'
require 'json'

set :public, Proc.new { File.join(root, 'public') }
set :views, Proc.new { File.join(root, 'views') }

puts "*** Must be run in production mode (-e production)"

module JsChat
  class Server
    attr_reader :connection

    def initialize(cookie)
      @cookie = cookie
      run
    end

    module EventServer
      include Rack::Utils
      alias_method :h, :escape_html

      def post_init
        @identified = false
        @messages = []

        watch_timeout
      end

      def polled
        @last_poll = Time.now
      end

      def watch_timeout
        @last_poll = Time.now

        Thread.new do
          loop do
            if Time.now - @last_poll > 120
              puts "TIMEOUT"
              close_connection
              return
            end
            sleep 120
          end
        end
      end

      def identified?
        @identified
      end

      def messages
        @messages
      end

      def room=(room)
        @room = room
      end

      def unbind
        puts "*** Server disconnecting.  Count now: #{JsChat::Bridge.servers.size}"
        JsChat::Bridge.servers.delete_if { |hash, server| server.connection == self }
        puts "*** Server disconnected.  Count now: #{JsChat::Bridge.servers.size}"
      end

      def receive_data(data)
        json = JSON.parse(data)

        puts "LINE FROM SERVER: #{data}"

        if @identified == false and json['identified']
          @identified = true
          @name = json['name']
          puts "*** IDENTIFIED, JOINING ROOM"
          send_data({'join' => @room}.to_json)
        elsif @identified and json['display'] == 'join'
          puts "*** Channel joined"
        elsif @identified
          @messages << sanitize_json(json).to_json
        end
      end

      def sanitize_json(json)
        # Sanitize output
        json.each do |field, value|
          if value.kind_of? String
            json[field] = h value
          elsif value.kind_of? Hash
            json[field] = sanitize_json(value)
          elsif value.kind_of? Array
            json[field] = value.collect do |v|
              if v.kind_of? String
                h v
              else
                sanitize_json(v)
              end
            end
          end
        end
        json
      end
    end

    def quit
      @connection.close_connection
    end

    def room=(room)
      @connection.room = room
    end

    def identify(name)
      @connection.send_data({'identify' => name}.to_json)
    end

    def identified?
      @connection.identified?
    end

    def run
      EM.run do
        @connection = EM.connect '0.0.0.0', 6789, EventServer
      end
    end

    def recent_messages
      messages = @connection.messages.dup
      @connection.messages.clear
      messages
    end
    
    def send_message(message)
      @connection.send_data({ 'to' => '#merk', 'send' => message }.to_json + "\n")
    end
  end

  class Bridge
    @@servers = {}
    attr_accessor :name, :server

    def initialize(cookie)
      @cookie = cookie
      setup_connection
    end

    def self.servers
      @@servers
    end

    def self.new_cookie
      SHA1.hexdigest Time.now.usec.to_s
    end

    def self.new_server(cookie)
      server = Server.new cookie
      @@servers[cookie] = server
    end

    def recent_messages
      @server.recent_messages
    end

    def setup_connection
      if @@servers[@cookie]
        @server = @@servers[@cookie]
      else
        Bridge.new_server(@cookie)
        @server = @@servers[@cookie]
      end
    end
  end
end

helpers do
  include Rack::Utils
  alias_method :h, :escape_html

  def message_form
    html = <<-HTML
      <ul id="messages">
      </ul>
      <div id="input">
        <form method="post" action="/message" id="post_message">
          Enter message: <input name="message" id="message" value="" type="text" />
        </form>
      </div>
    HTML
  end

  def load_bridge
    cookie = request.cookies['jschat-id']

    if cookie.nil?
      cookie = JsChat::Bridge.new_cookie
      response.set_cookie 'jschat-id', cookie
      JsChat::Bridge.new_server cookie
    end

    @bridge = JsChat::Bridge.new(cookie) 
  end

  def messages_js
    '[' + @bridge.recent_messages.join(", ") + ']';
  end
end

# Identify
get '/' do
  html = <<-HTML
    <form method="post" action="/identify">
      Enter name: <input name="name" id="name" value="" type="text" />
      and room: <input name="room" id="room" value="#merk" type="room" />
      <input type="submit" value="Go" />
    </form> 
  HTML
  erb html
end

post '/identify' do
  load_bridge
  @bridge.server.identify params['name']
  @bridge.server.room = params['room']

  redirect '/identify-pending'
end

# Invalid nick names should be handled
get '/identify-pending' do
  load_bridge

  if @bridge.server.identified?
    redirect '/chat'
  else
    "Not identified yet, please refresh"
  end
end

get '/messages' do
  load_bridge
  @bridge.server.connection.polled
  messages_js
end

get '/chat' do
  load_bridge
  erb message_form
end

post '/message' do
  load_bridge
  @bridge.server.send_message params['message']
  "Message posted"
end

post '/quit' do
  load_bridge
  @bridge.server.quit
  "Quit"
end
