# Status checks for Push - v0.1
require 'httparty'
require 'json'
require 'byebug'

StatusCheck = Struct.new(:passed, :error_message)

class PushChecks

  def self.check_status(push_url, languages = ['en'])
    results = {}
    languages.each { |language| results[language] = StatusCheck.new(false, nil) }

    languages.each do |language|
      status_check = results[language]

      url = push_url + "/articles.json?categories=true&language=#{language}"
      response = HTTParty.get(url)
      if response.code != 200
        status_check[:error_message] = "Non-successful response returned: Error code #{response.code}"
        next
      end

      if response.body.nil? || response.body.empty?
        status_check[:error_message] = 'Empty response'
        next
      end

      begin
        json = JSON.parse(response.body)
      rescue
        status_check[:error_message] = 'Response cannot be parsed into JSON'
        next
      end

      # Right now we'll just make sure that the results aren't empty
      if json.key? 'results'
        if !json['results'].empty?
          status_check[:passed] = true
        else
          status_check[:error_message] = 'Results array is empty'
        end
        next
      else
        status_check[:error_message] = 'No results array found in the response'
        next
      end

      status_check[:error_message] = "Unkown error with the results, try running #{url} in a browser to see what's wrong"
      results[language] = status_check
    end

    results
  end
end