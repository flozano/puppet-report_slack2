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

    @config["statuses"] ||= "changed,failed"
    statuses = @config["statuses"].split(",")

    pretext = "#{self.host} *#{self.status}* (#{self.environment})"

    if statuses.include?(self.status)
      case self.status
        when "changed"
          pretext = ":balloon: #{pretext}"
          color = 'good'
        when "failed"
          pretext = ":warning: #{pretext}"
          color = 'warning'
        when "unchanged"
          pretext = ":zzz: #{pretext}"
          color = '#cccccc'
        else
          pretext = ":grey_question: #{pretext}"
          color = 'warning'
      end

      payload = make_payload(pretext, message, color)

      @config["channels"].each do |channel|
        channel.gsub!(/^\\/, '')
        _payload = payload.merge("channel" => channel)
        post_to_webhook(URI.parse(@config["webhook"]), channel, _payload)
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

  def message
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
    log_text = self.logs.select { |x| self.status == 'failed' ||
        x.level == :warning || x.level == :err ||
        x.message =~ /\[(.*) changed to (.*)/
    }.
        sort { |a, b| a.time <=> b.time }.
        map { |x| "#{x.time} - #{x.level} - #{x.source}: #{x.message.gsub("\n", '')}" }.join("\n")

    return "```\n#{log_text.gsub(/^(.{6000,}?).*$/m, '\1\n...')}\n```"
  end

  def make_payload(pretext, message, color)
    {
        "username" => (@config["username"] || "puppet"),
        "attachments" => [{
                              "pretext" => pretext,
                              "text" => message,
                              "mrkdwn_in" => [:text, :pretext],
                              "color" => color,
                          }],
    }
  end

  def post_to_webhook(uri, channel, payload)
    https = Net::HTTP.new(uri.host, 443)
    https.use_ssl = true
    result = https.post(uri.path, payload.to_json)
    Puppet.err("POST returned #{result.code} #{result.msg} (body=#{result.body})") unless result.code == 200
    result
  end
end
