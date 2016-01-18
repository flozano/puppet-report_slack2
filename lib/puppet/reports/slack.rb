require 'puppet'
require 'puppet/network/http_pool'
require 'net/https'
require 'uri'
require 'json'

Puppet::Reports.register_report(:slack) do

  def process
    configdir = File.dirname(Puppet.settings[:config])
    configfile = File.join(configdir, 'slack.yaml')
    raise(Puppet::ParseError, "Slack report config file #{configfile} not readable") unless File.file?(configfile)

    @config = YAML.load_file(configfile)

    @config['statuses'] ||= 'changed,failed'
    statuses = @config['statuses'].split(',')


    if statuses.include?(self.status)
      @config['channels'].each do |channel|
        channel.gsub!(/^\\/, '')
        post_to_webhook(URI.parse(@config['webhook']), channel)
        Puppet.notice("Notification sent to slack channel: #{channel}")
      end
    end
  end

  def status_of(r)
    if r.failed then
      return 'failed'
    elsif r.skipped then
      return 'skipped'
    elsif r.changed then
      return 'changed'
    else
      return 'unchanged'
    end
  end

  private

  def payload
    {
        'username' => (@config['username'] || 'puppet'),
        'attachments' => [{
                              'pretext' => pretext,
                              'text' => full_message,
                              'mrkdwn_in' => [:text, :pretext],
                              'color' => color,
                          }],
    }
  end

  def post_to_webhook(uri, channel)
    https = Net::HTTP.new(uri.host, 443)
    https.use_ssl = true
    result = https.post(uri.path, payload.merge('channel' => channel).to_json)
    Puppet.err("POST returned #{result.code} #{result.msg} (body=#{result.body})") unless result.code == 200
    result
  end

  def pretext
    "#{status_icon} #{self.host} *#{self.status}* (#{self.environment})"
  end


  def full_message
    resources_message + logs_message
  end

  def resources_message
    value = ''
    self.resource_statuses.values.select { |x| x.changed || x.failed }.
        group_by { |r| self.status_of(r) }.
        each { |st, resources|
      value=value+"*#{st}*:  #{resources.map { |r| "#{r.resource_type}[#{r.title}]" }.join(', ')}\n"
    }
    value
  end

  def logs_message
    entries_to_log = self.logs.select { |x| self.status == 'failed' ||
        x.level == :warning || x.level == :err ||
        x.message =~ /(.*)changed to(.*)/
    }
    return '' if entries_to_log.empty?

    log_text = entries_to_log.sort { |a, b| a.time <=> b.time }.
        map { |x| "#{x.time} - #{x.level} - #{x.source}: #{x.message.gsub("\n", '')}" }.join("\n")

    return "```\n#{log_text.gsub(/^(.{6000,}?).*$/m, "\1\n...")}\n```"
  end

  def color
    case self.status
      when 'changed'
        return 'good'
      when 'failed'
        return 'warning'
      when 'unchanged'
        return '#cccccc'
      else
        return 'warning'
    end
  end

  def status_icon
    case self.status
      when 'changed'
        return ':balloon:'
      when 'failed'
        return ':warning:'
      when 'unchanged'
        return ':zzz:'
      else
        return ':grey_question:'
    end
  end


end
