defmodule CoordinatorStatus do
  use TypedStruct

  typedstruct enforce: true do
    field :current_activity, GameStatus.t() | none()
    field :queue, [{module(), any(), binary()}]
  end
end
