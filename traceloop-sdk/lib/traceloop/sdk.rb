require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require 'opentelemetry-semantic_conventions_ai'

module Traceloop
  module SDK
    class Traceloop
      def initialize
        OpenTelemetry::SDK.configure do |c|
          c.add_span_processor(
            OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
              OpenTelemetry::Exporter::OTLP::Exporter.new(
                endpoint: otlp_endpoint,
                headers: otlp_headers
              )
            )
          )
          puts "Traceloop exporting traces to #{otlp_endpoint}"
        end

        @tracer = OpenTelemetry.tracer_provider.tracer("Traceloop")
      end

      private

      def otlp_endpoint
        # Support standard OTEL env var, then Traceloop-specific, then default
        ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]&.then { |url| "#{url}/v1/traces" } ||
          "#{ENV.fetch("TRACELOOP_BASE_URL", "https://api.traceloop.com")}/v1/traces"
      end

      def otlp_headers
        # Support standard OTEL env var format: "key1=value1,key2=value2"
        if ENV["OTEL_EXPORTER_OTLP_HEADERS"]
          parse_headers(ENV["OTEL_EXPORTER_OTLP_HEADERS"])
        elsif ENV["TRACELOOP_API_KEY"]
          { "Authorization" => "Bearer #{ENV["TRACELOOP_API_KEY"]}" }
        else
          {}
        end
      end

      def parse_headers(headers_string)
        headers_string.split(",").each_with_object({}) do |pair, hash|
          key, value = pair.split("=", 2)
          hash[key.strip] = value&.strip || ""
        end
      end

      public

      class Tracer
        def initialize(span, provider, model)
          @span = span
          @provider = provider
          @model = model
        end

        def log_messages(messages)
          messages.each_with_index do |message, index|
            content = message[:content].is_a?(Array) ? message[:content].to_json : (message[:content] || "")
            @span.add_attributes({
              "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_PROMPTS}.#{index}.role" => message[:role] || "user",
              "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_PROMPTS}.#{index}.content" => content,
            })
          end
        end

        def log_prompt(system_prompt="", user_prompt)
          unless system_prompt.empty?
            @span.add_attributes({
              "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_PROMPTS}.0.role" => "system",
              "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_PROMPTS}.0.content" => system_prompt,
              "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_PROMPTS}.1.role" => "user",
              "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_PROMPTS}.1.content" => user_prompt
            })
          else
            @span.add_attributes({
              "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_PROMPTS}.0.role" => "user",
              "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_PROMPTS}.0.content" => user_prompt
            })
          end
        end

        def log_response(response)
          if response.respond_to?(:model_id) && response.respond_to?(:input_tokens) && response.respond_to?(:role)
            log_ruby_llm_response(response)
          elsif response.respond_to?(:body)
            log_bedrock_response(response)
          # This is Gemini specific, see -
          # https://github.com/gbaptista/gemini-ai?tab=readme-ov-file#generate_content
          elsif response.is_a?(Hash) && response.has_key?("candidates")
            log_gemini_response(response)
          else
            log_openai_response(response)
          end
        end

        def log_gemini_response(response)
          @span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_RESPONSE_MODEL => @model,
          })

          @span.add_attributes({
            "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_COMPLETIONS}.0.role" => "assistant",
            "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_COMPLETIONS}.0.content" => response.dig("candidates", 0, "content", "parts", 0, "text")
            })
        end

        def log_bedrock_response(response)
          body = JSON.parse(response.body.read())

          @span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_RESPONSE_MODEL => body.dig("model"),
          })
          if body.has_key?("usage")
            input_tokens = body.dig("usage", "input_tokens")
            output_tokens = body.dig("usage", "output_tokens")

            @span.add_attributes({
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_TOTAL_TOKENS => input_tokens + output_tokens,
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_COMPLETION_TOKENS => output_tokens,
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_PROMPT_TOKENS => input_tokens,
            })
          end
          if body.has_key?("content")
            @span.add_attributes({
            "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_COMPLETIONS}.0.role" => body.dig("role"),
            "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_COMPLETIONS}.0.content" => body.dig("content").first.dig("text")
            })
          end

          response.body.rewind()
        end

        def log_openai_response(response)
          @span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_RESPONSE_MODEL => response.dig("model"),
          })
          if response.has_key?("usage")
            @span.add_attributes({
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_TOTAL_TOKENS => response.dig("usage", "total_tokens"),
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_COMPLETION_TOKENS => response.dig("usage", "completion_tokens"),
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_PROMPT_TOKENS => response.dig("usage", "prompt_tokens"),
            })
          end
          if response.has_key?("choices")
            @span.add_attributes({
            "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_COMPLETIONS}.0.role" => response.dig("choices", 0, "message", "role"),
            "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_COMPLETIONS}.0.content" => response.dig("choices", 0, "message", "content")
            })
          end
        end

        def log_ruby_llm_response(response)
          @span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_RESPONSE_MODEL => response.model_id,
          })

          input_tokens = response.input_tokens || 0
          output_tokens = response.output_tokens || 0

          if input_tokens > 0 || output_tokens > 0
            @span.add_attributes({
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_PROMPT_TOKENS => input_tokens,
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_COMPLETION_TOKENS => output_tokens,
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_TOTAL_TOKENS => input_tokens + output_tokens,
            })
          end

          if response.respond_to?(:cached_tokens) && response.cached_tokens
            @span.add_attributes({
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_CACHED_TOKENS => response.cached_tokens,
            })
          end
          if response.respond_to?(:cache_creation_tokens) && response.cache_creation_tokens
            @span.add_attributes({
              OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_USAGE_CACHE_CREATION_TOKENS => response.cache_creation_tokens,
            })
          end

          content = extract_ruby_llm_content(response.content)
          @span.add_attributes({
            "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_COMPLETIONS}.0.role" => response.role.to_s,
            "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_COMPLETIONS}.0.content" => content,
          })

          if response.respond_to?(:tool_calls) && response.tool_calls && !response.tool_calls.empty?
            log_ruby_llm_tool_calls(response.tool_calls)
          end
        end

        def log_functions(functions)
          @span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_REQUEST_FUNCTIONS => functions.to_json
          })
        end

        private

        def extract_ruby_llm_content(content)
          case content
          when String
            content
          when nil
            ""
          else
            content.respond_to?(:text) ? content.text.to_s : content.to_s
          end
        end

        def log_ruby_llm_tool_calls(tool_calls)
          tool_calls.each_with_index do |tool_call, index|
            prefix = "#{OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_COMPLETIONS}.0.tool_calls.#{index}"

            attributes = {}
            attributes["#{prefix}.id"] = tool_call.id if tool_call.respond_to?(:id) && tool_call.id
            attributes["#{prefix}.name"] = tool_call.name if tool_call.respond_to?(:name) && tool_call.name

            if tool_call.respond_to?(:arguments) && tool_call.arguments
              args = tool_call.arguments
              attributes["#{prefix}.arguments"] = args.is_a?(String) ? args : args.to_json
            end

            @span.add_attributes(attributes) unless attributes.empty?
          end
        end
      end

      def llm_call(provider, model)
        @tracer.in_span("#{provider}.chat") do |span|
          span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::LLM_REQUEST_MODEL => model,
          })
          yield Tracer.new(span, provider, model)
        end
      end

      def workflow(name)
        @tracer.in_span("#{name}.workflow") do |span|
          span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::TRACELOOP_SPAN_KIND => "workflow",
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::TRACELOOP_ENTITY_NAME => name,
          })
          yield
        end
      end

      def task(name)
        @tracer.in_span("#{name}.task") do |span|
          span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::TRACELOOP_SPAN_KIND => "task",
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::TRACELOOP_ENTITY_NAME => name,
          })
          yield
        end
      end

      def agent(name)
        @tracer.in_span("#{name}.agent") do |span|
          span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::TRACELOOP_SPAN_KIND => "agent",
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::TRACELOOP_ENTITY_NAME => name,
          })
          yield
        end
      end

      def tool(name)
        @tracer.in_span("#{name}.tool") do |span|
          span.add_attributes({
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::TRACELOOP_SPAN_KIND => "tool",
            OpenTelemetry::SemanticConventionsAi::SpanAttributes::TRACELOOP_ENTITY_NAME => name,
          })
          yield
        end
      end
    end
  end
end
