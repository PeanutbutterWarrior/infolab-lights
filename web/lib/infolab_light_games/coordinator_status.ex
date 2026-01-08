defmodule CoordinatorStatus do
  use TypedStruct

  typedstruct enforce: true do
    field :current_activity, GameStatus.t() | none()
    field :queue, [GameStatus.t()]
  end
end
