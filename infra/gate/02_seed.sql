-- Seed for the gate table: 50,000 providers clustered around three cities.
-- Karachi 20,000 (40%), Lahore 17,500 (35%), Islamabad 12,500 (25%).
-- The split, the spread and the 60% online share are our assumptions.
-- Random with a fixed seed, so every run gives the same data.
SELECT setseed(0.42);

TRUNCATE gate_provider_locations RESTART IDENTITY;

INSERT INTO gate_provider_locations (location, online, category_id)
SELECT
    ST_SetSRID(
        ST_MakePoint(
            c.lon + (random() + random() + random() - 1.5) * 0.1,
            c.lat + (random() + random() + random() - 1.5) * 0.1
        ), 4326)::geography,
    random() < 0.6,
    (1 + floor(random() * 10))::smallint
FROM (
    SELECT n,
        CASE WHEN n <= 20000 THEN 67.0011
             WHEN n <= 37500 THEN 74.3587
             ELSE 73.0479 END AS lon,
        CASE WHEN n <= 20000 THEN 24.8607
             WHEN n <= 37500 THEN 31.5204
             ELSE 33.6844 END AS lat
    FROM generate_series(1, 50000) AS n
) AS c;

ANALYZE gate_provider_locations;