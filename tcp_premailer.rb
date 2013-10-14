#!/usr/bin/env ruby

require 'eventmachine'
require 'premailer'
require 'nokogiri'
require 'yaml'
require 'tempfile'
require 'memcached'
require 'logger'

$config=YAML.load(File.open('config/tcp_premailer.yaml'))

class MailNet < EventMachine::Connection
	def initialize(*args)
		@ip = nil
		@digest = nil

		@cache=Memcached.new("#{$config['memcached_host'].to_s}:#{$config['memcached_port'].to_s}")
		@warn = Logger.new($config['logfile']+".warn",'monthly')
		@warn.level = Logger::WARN	
		@warn.formatter = proc do |severity, datetime, progname, msg|
			"[#{severity}] #{datetime} (#{@ip}): #{msg}\n"
		end
		@log = Logger.new($config['logfile']+".log",'monthly')
		@log.level = Logger::INFO
		@log.formatter = @warn.formatter
		super
	end
	
	def receive_data(data)
		port, @ip = Socket.unpack_sockaddr_in(get_peername)
		unless $config['username']==data[/^([^:]+):/,1] and $config['password']==data[/^[^:]+:([^:]+):/,1] and $config['allowed'].include?(@ip)
			@log.fatal "Auth fail"
			close_connection
			return false
		end
		@digest=Digest.hexencode(Digest::SHA256.new.digest(data[/^[^:]+:[^:]+:(.*)/mi,1]))
		icss=nil
		@log.info "Data received"
		begin
			send_data @cache.get(@digest)
			@log.info "Sent from cache: #{@digest}"
		rescue Memcached::NotFound
			html=Tempfile.new('mail') 
			html.write data[/^[^:]+:[^:]+:(.*)/mi,1]
			html.rewind
			send_data(to_inline_css(html))
		end
		send_data "<!-- "+@digest.to_s+" -->\n"
		close_connection_after_writing
		@ip=nil
		@digest=nil
	end
	
	def to_inline_css(html)
			Premailer::Adapter.use = :nokogiri
			premailer = Premailer.new(html, :warn_level => Premailer::Warnings::RISKY)
			warns=[]
			icss=premailer.to_inline_css
			premailer.warnings.each do |w|
				warns.push "#{w[:message]}:(#{w[:level]}): #{w[:clients]}"
			end
			html.close
			html.unlink
			@log.info "Caching with digest: #{@digest}" unless @digest==nil
			@cache.set(@digest,icss) unless @digest==nil
			warns.each{|w| @warn.warn w}
			@cache.set("warnings-"+@digest,warns)
			@log.info "Cached warnings: warnings-"+@digest if warns.length > 0
			return icss
	end
end

EventMachine.run do 
	EventMachine.start_server $config['host'], $config['port'], MailNet
end
