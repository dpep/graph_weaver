require "date"
require "graphql"

# A small in-process schema to query against, including a custom scalar
# (Date) to explore how graphql-client handles deserialization.
module Demo
  Pet = Struct.new(:id, :name, keyword_init: true)
  Person = Struct.new(:id, :name, :birthday, :pets, keyword_init: true)

  PETS = [
    Pet.new(id: "1", name: "Shelby"),
    Pet.new(id: "2", name: "Brownie"),
  ]

  PEOPLE = [
    Person.new(id: "1", name: "Daniel", birthday: Date.new(1990, 6, 15), pets: PETS),
  ]

  class DateType < GraphQL::Schema::Scalar
    graphql_name "Date"

    def self.coerce_result(value, _ctx)
      value.iso8601
    end

    def self.coerce_input(value, _ctx)
      Date.iso8601(value)
    end
  end

  class PetType < GraphQL::Schema::Object
    graphql_name "Pet"

    field :id, ID, null: false
    field :name, String, null: false
  end

  class PersonType < GraphQL::Schema::Object
    graphql_name "Person"

    field :id, ID, null: false
    field :name, String, null: false
    field :birthday, DateType
    field :pets, [PetType], null: false
  end

  class QueryType < GraphQL::Schema::Object
    graphql_name "Query"

    field :person, PersonType do
      argument :id, ID, required: true
    end

    def person(id:)
      PEOPLE.find { |p| p.id == id }
    end

    field :people, [PersonType], null: false

    def people
      PEOPLE
    end
  end

  class Schema < GraphQL::Schema
    query QueryType
  end
end
