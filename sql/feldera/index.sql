create table t0 (id int, s varchar) with (
  'connectors' = '[{
    "name": "datagen",
    "transport": {
      "name": "datagen",
      "config": {
        "plan": [{
          "rate": 1,
          "limit": 5
        }]
      }
    }
  }]'
);

create materialized view v1 with (
    'connectors' = '[{
        "name": "postgres_output",
        "index": "v1_idx",
        "transport": {
            "name": "postgres_output",
            "config": {
                "uri": "postgres://postgres@localhost:5432/postgres",
                "table": "feldera_out"
            }
        }
    }]'
) as select * from t0;

create index v1_idx on v1(id);
