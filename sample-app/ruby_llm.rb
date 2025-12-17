require "ruby_llm"
require "traceloop/sdk"

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
end

traceloop = Traceloop::SDK::Traceloop.new

traceloop.workflow("joke_generator") do
  traceloop.llm_call(provider = "anthropic", model = "claude-sonnet-4-20250514") do |tracer|
    chat = RubyLLM.chat(model: "claude-sonnet-4-20250514")

    tracer.log_prompt(user_prompt = "Tell me a joke about OpenTelemetry")
    response = chat.ask("Tell me a joke about OpenTelemetry")
    tracer.log_response(response)

    puts response.content
  end
end

class WeatherTool < RubyLLM::Tool
  description "Get the current weather for a location"

  param :location, desc: "City name"

  def execute(location:)
    "Sunny, 72F in #{location}"
  end
end

traceloop.workflow("weather_assistant") do
  traceloop.llm_call(provider = "anthropic", model = "claude-sonnet-4-20250514") do |tracer|
    chat = RubyLLM.chat(model: "claude-sonnet-4-20250514")
    chat.with_tool(WeatherTool)

    tracer.log_functions([{
      name: "WeatherTool",
      description: "Get the current weather for a location",
      parameters: { location: { type: "string", description: "City name" } }
    }])

    tracer.log_prompt(user_prompt = "What's the weather in San Francisco?")
    response = chat.ask("What's the weather in San Francisco?")
    tracer.log_response(response)

    puts response.content
  end
end
