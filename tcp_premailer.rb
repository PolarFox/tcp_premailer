#!/usr/bin/env ruby

require 'eventmachine'
require 'premailer'
require 'nokogiri'
require 'yaml'
require 'tempfile'
require 'memcached'
require 'logger'

$config=YAML.load(File.open(File.dirname(__FILE__)+'/config/tcp_premailer.yaml'))

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
		send_data "<!-- DIGEST::"+@digest.to_s+"::DIGEST -->\n"
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

def run
	EventMachine.run do 
		EventMachine.start_server $config['host'], $config['port'], MailNet
	end
end

def get_pid
	if File.exists?($config['pidfile'])
		file = File.new($config['pidfile'], "r")
		pid = file.read
		file.close
 
		pid
	else
		0
	end
end

def start
	pid = get_pid
	if pid != 0
		warn "Daemon is already running"
		exit -1
	end
	 
	pid = fork {
		run
	}
	begin
		file = File.new($config['pidfile'], "w")
		file.write(pid)
		file.close
		Process.detach(pid)
	rescue => exc
		Process.kill('TERM', pid)
		warn "Cannot start daemon: #{exc.message}"
	end
end

def stop
	pid = get_pid
	begin
		EM.stop
	rescue
	end
	 
	if pid != 0
		Process.kill('HUP', pid.to_i)
		File.delete($config['pidfile'])
		puts "Stopped"
	else
		warn "Daemon is not running"
		exit -1
	end
end

case ARGV[0]
	when 'start'
		start
	when 'stop'
		stop
	when 'foreground'
	    run
	else
		exit
end
