module QuintDriver
  class Spec
    # A driver for this module to start from, as Ruby source: one `when` per
    # action the step action can take, with the picks it receives, and one
    # key per variable `state` must report, with the Ruby shape of its value.
    # The expectations, the boolean vals and defs without parameters, are
    # listed for invariants: and violate:. Raises Unsupported, as a replay
    # would, when the step action has a shape the driver protocol cannot run,
    # so the outline is also the check that a driver can be written at all.
    def outline(step = "step")
      picks = rules(step).each_with_object({ "init" => {} }) do |rule, actions|
        (actions[rule.action] ||= {}).merge!(rule.domains.transform_values { shape(@types.dig(_1["id"].to_s, "type", "elem")) })
      end
      variables = declarations.sort_by { _1["id"] }.select { _1["kind"] == "var" }
      # A name that starts with an underscore splits into an empty first word.
      name = @main.split(/[^A-Za-z0-9]+/).map { _1[0].to_s.upcase + _1[1..].to_s }.join
      [ "# A driver for the module #{@main}, whose step action is #{step}.",
        "# Expectations, for invariants: or violate:",
        *expectations.map { "#   #{_1}" }.then { _1.empty? ? [ "#   none yet: write what the operator expects as boolean vals" ] : _1 },
        "class #{name}Driver",
        "  def step(action, picks)",
        "    case action",
        *picks.map { |action, given| "    when #{action.dump}#{" # #{given.map { "picks[#{_1.dump}]: #{_2}" }.join(', ')}" unless given.empty?}" },
        "    end",
        "  end",
        "",
        "  # A variable the system does not keep, such as a pick the spec",
        "  # remembers, goes in ignore: instead of here.",
        "  def state",
        "    {",
        *variables.map { "      #{_1['name'].dump} => nil, # #{shape(_1['typeAnnotation'])}" },
        "    }",
        "  end",
        "end",
        "" ].join("\n")
    end

    private
      # The Ruby value a driver reports for a Quint type, as `state` and the
      # picks take them: see "Write the driver" in the skill.
      def shape(type, seen = Set.new)
        case type&.fetch("kind")
        when "int" then "Integer"
        when "str" then "String"
        when "bool" then "true or false"
        when "set" then "Set of #{shape(type['elem'], seen)}"
        when "list" then "Array of #{shape(type['elem'], seen)}"
        when "fun" then "Hash of #{shape(type['arg'], seen)} => #{shape(type['res'], seen)}"
        when "tup" then "[#{type.dig('fields', 'fields').map { shape(_1['fieldType'], seen) }.join(', ')}]"
        when "rec" then "{#{type.dig('fields', 'fields').map { "#{_1['fieldName'].dump} => #{shape(_1['fieldType'], seen)}" }.join(', ')}}"
        when "sum" then cases(type.dig("fields", "fields"), seen)
        when "const"
          typedef = declarations.find { _1["kind"] == "typedef" && _1["name"] == type["name"] && _1["type"] }
          typedef && !seen.include?(type["name"]) ? shape(typedef["type"], seen | [ type["name"] ]) : type["name"]
        else type ? type["kind"] : "any value"
        end
      end

      def cases(fields, seen)
        tags = fields.map { _1["fieldName"] }
        if tags.sort == %w[None Some]
          return "nil or #{shape(fields.find { _1['fieldName'] == 'Some' }['fieldType'], seen)}"
        end
        each = fields.map do |field|
          empty = field.dig("fieldType", "kind") == "tup" && field.dig("fieldType", "fields", "fields").empty?
          empty ? field["fieldName"].dump : "[#{field['fieldName'].dump}, #{shape(field['fieldType'], seen)}]"
        end
        each.size > 1 ? "#{each[0..-2].join(', ')} or #{each[-1]}" : each.first
      end
  end
end
