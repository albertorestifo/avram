require "db"
require "levenshtein"
require "./schema_enforcer"
require "./polymorphic"

abstract class Avram::Model
  include Avram::Associations
  include Avram::Polymorphic
  include Avram::SchemaEnforcer

  macro inherited
    COLUMNS      = [] of Nil # types are not checked in macros
    ASSOCIATIONS = [] of Nil # types are not checked in macros
    include LuckyCache::Cachable
    include DB::Serializable
  end

  def self.primary_key_name : Symbol?
    nil
  end

  def self.database_table_info : Avram::Database::TableInfo?
    database.database_info.table(table_name.to_s)
  end

  def model_name : String
    self.class.name
  end

  # Refer to `PrimaryKeyMethods#reload`
  def reload : self
    {% raise "Unable to call Avram::Model#reload on #{@type.name} because it does not have a primary key. Add a primary key or define your own `reload` method." %}
  end

  # Refer to `PrimaryKeyMethods#reload`
  def reload(&) : self
    {% raise "Unable to call Avram::Model#reload on #{@type.name} because it does not have a primary key. Add a primary key or define your own `reload` method." %}
  end

  # Refer to `PrimaryKeyMethods#to_param`
  def to_param : String
    {% raise "Unable to call Avram::Model#to_param on #{@type.name} because it does not have a primary key. Add a primary key or define your own `to_param` method." %}
  end

  # Refer to `PrimaryKeyMethods#delete`
  def delete
    {% raise "Unable to call Avram::Model#delete on #{@type.name} because it does not have a primary key. Add a primary key or define your own `delete` method." %}
  end

  macro table(table_name = nil)
    default_columns

    {{ yield }}

    validate_columns("table")
    validate_primary_key

    {% if table_name %}
    class_getter table_name : String = {{ table_name.id.stringify }}
    {% else %}
    class_getter table_name : String = Avram::TableFor.table_for({{ @type.id }})
    {% end %}
    setup(Avram::Model.setup_initialize)
    setup(Avram::Model.setup_getters)
    setup(Avram::Model.setup_column_info_methods)
    setup(Avram::Model.setup_association_queries)
    setup(Avram::Model.setup_table_schema_enforcer_validations)
    setup(Avram::BaseQueryTemplate.setup)
    setup(Avram::SaveOperationTemplate.setup)
    setup(Avram::DeleteOperationTemplate.setup)
    setup(Avram::SchemaEnforcer.setup)
  end

  macro view(view_name = nil)
    {{ yield }}

    validate_columns("view")
    {% if view_name %}
      class_getter table_name : String = {{ view_name.id.stringify }}
    {% else %}
      class_getter table_name : String = Avram::TableFor.table_for({{ @type.id }})
    {% end %}
    setup(Avram::Model.setup_initialize)
    setup(Avram::Model.setup_getters)
    setup(Avram::Model.setup_column_info_methods)
    setup(Avram::Model.setup_association_queries)
    setup(Avram::Model.setup_view_schema_enforcer_validations)
    setup(Avram::BaseQueryTemplate.setup)
    setup(Avram::SchemaEnforcer.setup)
  end

  macro primary_key(type_declaration, value_generator = nil)
    PRIMARY_KEY_TYPE = {{ type_declaration.type }}
    PRIMARY_KEY_NAME = {{ type_declaration.var.symbolize }}
    column {{ type_declaration.var }} : {{ type_declaration.type }}, autogenerated: true
    alias PrimaryKeyType = {{ type_declaration.type }}

    def self.primary_key_name : Symbol?
      :{{ type_declaration.var.stringify }}
    end

    {% if type_declaration.type.stringify == "String" %}
      {% if !value_generator || value_generator && !(value_generator.is_a?(ProcLiteral) || value_generator.is_a?(ProcPointer) || value_generator.is_a?(Call)) %}
          {% raise <<-ERROR
              When using a String primary_key, you must also specify a way to generate the value.
              You can provide a class method, a proc or a proc pointer.
              Your value generator must return a non-nullable String.

              Example:
                #{@type.id} do
                  primary_key id : String, Random::Secure.hex
                  ...
                end

              Or with a proc:
                #{@type} do
                  primary_key id : String, value_generator: -> { Random::Secure.hex }
                  ...
                end
              ERROR
          %}
      {% end %}

      def self.primary_key_value_generator : String
        {% if value_generator.is_a?(ProcLiteral) || value_generator.is_a?(ProcPointer) %}
          {{value_generator}}.call
        {% else %}
          {{value_generator}}
        {% end %}
      end

    {% end %}

    include Avram::PrimaryKeyMethods

    # If not using default 'id' primary key
    {% if type_declaration.var.id != "id".id %}
      # Then point 'id' to the primary key
      def id
        {{ type_declaration.var.id }}
      end
    {% end %}
  end

  macro validate_primary_key
    {% if !@type.has_constant? "PRIMARY_KEY_TYPE" %}
      \{% raise <<-ERROR
        No primary key was specified.

        Example:

          table do
            primary_key id : Int64
            ...
          end
        ERROR
      %}
    {% end %}
  end

  macro default_columns
    primary_key id : Int64
    timestamps
  end

  macro skip_default_columns
    macro default_columns
    end
  end

  macro timestamps
    column created_at : Time, autogenerated: true
    column updated_at : Time, autogenerated: true
  end

  macro setup(step)
    {{ step.id }}(
      type: {{ @type }},
      columns: {{ COLUMNS }},
      associations: {{ ASSOCIATIONS }}
    )
  end

  macro validate_columns(model_type)
    {% if COLUMNS.empty? %}
      {% raise <<-ERROR
        #{@type} must define at least one column.

        Example:

          #{model_type.id} do
            primary_key id : Int64
            ...
          end
        ERROR
      %}
    {% end %}
  end

  macro setup_initialize(columns, *args, **named_args)
    def initialize(
        {% for column in columns %}
          @{{column[:name]}},
        {% end %}
      )
    end
  end

  macro setup_association_queries(associations, *args, **named_args)
    {% for assoc in associations %}
      def {{ assoc[:assoc_name] }}_query
        {% if assoc[:relationship_type] == :has_many %}
          {{ assoc[:type] }}::BaseQuery.new.{{ assoc[:foreign_key].id }}(id)
        {% elsif assoc[:relationship_type] == :belongs_to %}
          {{ assoc[:type] }}::BaseQuery.new.id({{ assoc[:foreign_key].id }})
        {% else %}
          {{ assoc[:type] }}::BaseQuery.new
        {% end %}
      end
    {% end %}
  end

  macro setup_table_schema_enforcer_validations(type, *args, **named_args)
    schema_enforcer_validations << EnsureExistingTable.new(model_class: {{ type.id }})
    schema_enforcer_validations << EnsureMatchingColumns.new(model_class: {{ type.id }})
  end

  macro setup_view_schema_enforcer_validations(type, *args, **named_args)
    schema_enforcer_validations << EnsureExistingTable.new(model_class: {{ type.id }})
    schema_enforcer_validations << EnsureMatchingColumns.new(model_class: {{ type.id }}, check_required: false)
  end

  macro setup_getters(columns, *args, **named_args)
    {% for column in columns %}
      def {{column[:name]}} : {{column[:type]}}{{(column[:nilable] ? "?" : "").id}}
        {{ column[:type] }}.adapter.from_db!(@{{column[:name]}})
      end
      {% if column[:type].id == Bool.id %}
      def {{column[:name]}}? : Bool
        !!{{column[:name]}}
      end
      {% end %}
    {% end %}
  end

  macro column(type_declaration, autogenerated = false, serialize is_serialized = false, allow_blank = false)
    {% if type_declaration.type.is_a?(Union) %}
      {% data_type = type_declaration.type.types.first %}
      {% nilable = true %}
    {% else %}
      {% data_type = type_declaration.type %}
      {% nilable = false %}
    {% end %}
    {% if type_declaration.value || type_declaration.value == false %}
      {% value = type_declaration.value %}
    {% else %}
      {% value = nil %}
    {% end %}

    @[DB::Field(
      ignore: false,
      key: {{ type_declaration.var }},
      {% if is_serialized %}
      converter: JSONConverter({{ data_type }}),
      {% elsif data_type.id == Array(Float64).id %}
      converter: PG::NumericArrayFloatConverter,
      {% end %}
    )]
    {% if data_type.is_a?(Generic) || is_serialized %}
      @{{ type_declaration.var }} : {{ data_type }}{% if nilable %}?{% end %}
    {% else %}
      @{{ type_declaration.var }} : {{ data_type }}::Lucky::ColumnType{% if nilable %}?{% end %}
    {% end %}

    {% COLUMNS << {name: type_declaration.var, type: data_type, nilable: nilable.id, autogenerated: autogenerated, value: value, serialized: is_serialized, allow_blank: allow_blank} %}
  end

  macro setup_column_info_methods(columns, *args, **named_args)
    def self.column_names : Array(Symbol)
      columns.map { |column| column[:name] }
    end

    def self.columns : Array({name: Symbol, nilable: Bool, type: String})
      [
        {% for column in columns %}
          {
            name: {{ column[:name].id.symbolize }},
            nilable: {{ column[:nilable] }},
            type: {{ column[:type].id }}.name
          },
        {% end %}
      ]
    end
  end

  macro association(assoc_name, type, relationship_type, foreign_key = nil, through = nil)
    {% ASSOCIATIONS << {type: type, assoc_name: assoc_name.id, foreign_key: foreign_key, relationship_type: relationship_type, through: through} %}
  end
end
