-- GiST index on the geography column (SRS v3.0 DR-04).
CREATE INDEX gate_provider_locations_location_gist
    ON gate_provider_locations USING gist (location);

ANALYZE gate_provider_locations;