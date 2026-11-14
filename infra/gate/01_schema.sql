-- Gate-only table for SB-E00-013 / SB-E00-004. Not product schema.
-- Safe to re-run: drops and recreates the gate table only.
CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS gate_provider_locations;

CREATE TABLE gate_provider_locations (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    location    geography(Point, 4326) NOT NULL,
    online      boolean NOT NULL,
    category_id smallint NOT NULL
);