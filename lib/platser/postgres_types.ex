Postgrex.Types.define(
  Platser.PostgresTypes,
  [Geo.PostGIS.Extension | Ecto.Adapters.Postgres.extensions()],
  json: Jason
)
