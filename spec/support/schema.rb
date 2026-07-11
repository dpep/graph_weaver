require "date"
require "graphql"

# A small in-process schema to query against, including a custom scalar
# (Date) to explore how graphql-client handles deserialization.
module Demo
  Pet = Struct.new(:id, :name, :species, keyword_init: true)
  Person = Struct.new(:id, :name, :birthday, :pets, keyword_init: true)

  PETS = [
    Pet.new(id: "1", name: "Shelby", species: "DOG"),
    Pet.new(id: "2", name: "Brownie", species: "CAT"),
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

  class SpeciesType < GraphQL::Schema::Enum
    graphql_name "Species"

    value "DOG"
    value "CAT"
  end

  module NamedType
    include GraphQL::Schema::Interface
    graphql_name "Named"

    field :name, String, null: false
  end

  class PetType < GraphQL::Schema::Object
    graphql_name "Pet"
    implements NamedType

    field :id, ID, null: false
    field :name, String, null: false
    field :species, SpeciesType, null: false
  end

  class PersonType < GraphQL::Schema::Object
    graphql_name "Person"
    implements NamedType

    field :id, ID, null: false
    field :name, String, null: false
    field :email, String # resolved nowhere; exists for FakeExecutor specs
    field :birthday, DateType
    field :pets, [PetType], null: false
  end

  class SearchResultType < GraphQL::Schema::Union
    graphql_name "SearchResult"
    possible_types PersonType, PetType

    def self.resolve_type(object, _ctx)
      object.is_a?(Person) ? PersonType : PetType
    end
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

    field :search, [SearchResultType], null: false do
      argument :term, String, required: true
      argument :first, Integer, required: false
    end

    def search(term:, first: nil)
      matches = (PEOPLE + PETS).select { |record| record.name.downcase.include?(term.downcase) }
      first ? matches.first(first) : matches
    end

    field :named, NamedType do
      argument :name, String, required: true
    end

    def named(name:)
      (PEOPLE + PETS).find { |record| record.name == name }
    end
  end

  class AdoptionInputType < GraphQL::Schema::InputObject
    graphql_name "AdoptionInput"

    argument :name, String, required: true
    argument :species, SpeciesType, required: true
    argument :nickname, String, required: false
    argument :birthday, DateType, required: false
  end

  class MutationType < GraphQL::Schema::Object
    graphql_name "Mutation"

    field :add_pet, PetType, null: false do
      argument :name, String, required: true
      argument :species, SpeciesType, required: true
    end

    # returns without persisting, so specs stay isolated
    def add_pet(name:, species:)
      Pet.new(id: "99", name:, species:)
    end

    field :adopt, PetType, null: false do
      argument :input, AdoptionInputType, required: true
    end

    def adopt(input:)
      Pet.new(id: "77", name: input[:nickname] || input[:name], species: input[:species])
    end
  end

  class Schema < GraphQL::Schema
    query QueryType
    mutation MutationType

    def self.resolve_type(_abstract_type, object, _ctx)
      object.is_a?(Person) ? PersonType : PetType
    end
  end
end
