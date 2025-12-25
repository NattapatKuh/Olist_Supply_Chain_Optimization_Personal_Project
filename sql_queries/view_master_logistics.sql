-- for create a view table in PowerBI
-- Fact Table
SELECT 
    oi.order_id,
    oi.order_item_id,
    oi.product_id,
    oi.seller_id,
    o.customer_id,
    DATE(o.order_purchase_timestamp) as purchase_date,
    DATE(o.order_approved_at) as approved_date,
    DATE(o.order_delivered_customer_date) as delivered_date,
    DATE(o.order_estimated_delivery_date) as estimated_date,
    oi.price,
    oi.freight_value,
    (oi.price + oi.freight_value) as total_value,
    c.customer_zip_code_prefix,
    s.seller_zip_code_prefix,
    c.customer_state,
    s.seller_state,
    CAST(julianday(o.order_delivered_customer_date) - julianday(o.order_estimated_delivery_date) AS INTEGER) as days_late,
    CAST(julianday(o.order_delivered_customer_date) - julianday(o.order_purchase_timestamp) AS INTEGER) as lead_time_days,
    CASE 
        WHEN s.seller_state = 'SP' AND c.customer_state = 'RJ' THEN 'Critical (SP->RJ)'
        WHEN s.seller_state = c.customer_state THEN 'Local (Same State)'
        ELSE 'Standard Inter-State'
    END as route_type,
    CASE 
        WHEN (julianday(o.order_delivered_customer_date) - julianday(o.order_estimated_delivery_date)) <= 0 THEN 'On Time'
        WHEN (julianday(o.order_delivered_customer_date) - julianday(o.order_estimated_delivery_date)) <= 3 THEN 'Minor Delay'
        ELSE 'Major Incident (Red Zone)'
    END as lateness_tier
FROM olist_order_items_dataset oi
JOIN olist_orders_dataset o ON oi.order_id = o.order_id
JOIN olist_order_customer_dataset c ON o.customer_id = c.customer_id
JOIN olist_sellers_dataset s ON oi.seller_id = s.seller_id
WHERE o.order_status = 'delivered'

-- Dim_Product
SELECT 
    p.product_id,
    p.product_category_name as category_name,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm,
    CASE 
        WHEN p.product_weight_g > 5000 OR p.product_length_cm > 100 THEN 'Bulky Item'
        ELSE 'Standard Item'
    END as logistics_type
FROM olist_products_dataset p

-- Dim_Geography
SELECT 
    geolocation_zip_code_prefix as zip_code,
    geolocation_city as city,
    geolocation_state as state,
    AVG(geolocation_lat) as latitude,
    AVG(geolocation_lng) as longitude
FROM olist_geolocation_dataset
GROUP BY 1, 2, 3

-- for Analysis in Jupyter, so we created query and saved via 'query' var to execute later
-- We extract SP->RJ route data specifically for the simulation
query = """
SELECT 
    o.order_id,
    o.order_estimated_delivery_date,
    o.order_delivered_customer_date,
    o.order_delivered_carrier_date,
    oi.freight_value,
    s.seller_state,
    c.customer_state
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
JOIN sellers s ON oi.seller_id = s.seller_id
WHERE 
    o.order_status = 'delivered'
    AND s.seller_state = 'SP' 
    AND c.customer_state = 'RJ'
"""

-- Objective: Identify Top 500 SKUs for "Project Rio Bypass"
-- Logic: Filter for RJ Destination -> Rank by Order Volume

query_vital_500 = """
SELECT 
    p.product_id,
    p.product_category_name,
    COUNT(oi.order_id) AS total_orders_in_rio,
    -- Impact: Revenue at Risk
    ROUND(SUM(oi.price), 2) AS total_revenue_in_rio,
    -- Context: Unit Economics
    ROUND(AVG(oi.price), 2) AS avg_item_price,
    -- Context: Logistics Cost (Current Pain)
    ROUND(AVG(oi.freight_value), 2) AS avg_current_freight_cost
FROM 
    order_items oi
JOIN 
    orders o ON oi.order_id = o.order_id
JOIN 
    products p ON oi.product_id = p.product_id
JOIN 
    customers c ON o.customer_id = c.customer_id
WHERE 
    -- FILTER 1: The Problem Zone (Rio)
    c.customer_state = 'RJ'
    -- FILTER 2: Active Timeline (Post-2017 to capture relevant trends)
    AND o.order_purchase_timestamp >= '2017-01-01'
GROUP BY 
    p.product_id, 
    p.product_category_name
ORDER BY 
    -- PRIORITY: Volume (Stopping the highest number of complaints)
    total_orders_in_rio DESC
LIMIT 500;
"""

-- 3. Extract Data for Regression (Delay vs Stars)
query_regression = """
SELECT 
    (JULIANDAY(o.order_delivered_customer_date) - JULIANDAY(o.order_estimated_delivery_date)) as delay_days,
    r.review_score
FROM order_items oi
JOIN orders o ON oi.order_id = o.order_id
JOIN order_reviews r ON oi.order_id = r.order_id
WHERE 
    o.order_status = 'delivered'
    AND o.order_delivered_customer_date IS NOT NULL
    -- We only care about LATE orders to measure the "Anger Penalty"
    -- Or we can look at all orders to see the curve
"""


-- We fetch the raw log needed to reconstruct the timeline
query = """
SELECT 
    o.order_id,
    o.order_status,
    o.order_purchase_timestamp,
    o.order_approved_at,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    c.customer_state
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered'
"""

-- We need a more complex join now to get Product Categories and Seller Locations
query = """
SELECT 
    o.order_id,
    o.order_status,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    c.customer_state,
    s.seller_state,
    p.product_category_name
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
-- We assume 1 item per order for the dominant logic (simplification for route analysis)
JOIN order_items oi ON o.order_id = oi.order_id
JOIN sellers s ON oi.seller_id = s.seller_id
JOIN products p ON oi.product_id = p.product_id
WHERE o.order_status = 'delivered'
"""

-- We need Estimated Date, Delivered Date, Freight Value, and Geography
query = """
SELECT 
    o.order_id,
    o.order_estimated_delivery_date,
    o.order_delivered_customer_date,
    o.order_delivered_carrier_date,
    oi.freight_value,
    s.seller_state,
    c.customer_state
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
JOIN sellers s ON oi.seller_id = s.seller_id
WHERE o.order_status = 'delivered'
"""

-- We extract SP->RJ route data specifically for the simulation
query = """
SELECT 
    o.order_id,
    o.order_estimated_delivery_date,
    o.order_delivered_customer_date,
    o.order_delivered_carrier_date,
    oi.freight_value,
    s.seller_state,
    c.customer_state
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
JOIN sellers s ON oi.seller_id = s.seller_id
WHERE 
    o.order_status = 'delivered'
    AND s.seller_state = 'SP' 
    AND c.customer_state = 'RJ'
"""

-- "The Great Unification" Query
query = """
SELECT 
    o.order_id,
    o.order_status,
    o.order_purchase_timestamp,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    c.customer_state,
    s.seller_state,
    p.product_category_name,
    oi.freight_value
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
JOIN sellers s ON oi.seller_id = s.seller_id
JOIN products p ON oi.product_id = p.product_id
WHERE o.order_status = 'delivered'
"""


-- Objective: Identify Top 500 SKUs for "Project Rio Bypass"
-- Logic: Filter for RJ Destination -> Rank by Order Volume

query_vital_500 = """
SELECT 
    p.product_id,
    p.product_category_name,
    COUNT(oi.order_id) AS total_orders_in_rio,
    -- Impact: Revenue at Risk
    ROUND(SUM(oi.price), 2) AS total_revenue_in_rio,
    -- Context: Unit Economics
    ROUND(AVG(oi.price), 2) AS avg_item_price,
    -- Context: Logistics Cost (Current Pain)
    ROUND(AVG(oi.freight_value), 2) AS avg_current_freight_cost
FROM 
    order_items oi
JOIN 
    orders o ON oi.order_id = o.order_id
JOIN 
    products p ON oi.product_id = p.product_id
JOIN 
    customers c ON o.customer_id = c.customer_id
WHERE 
    -- FILTER 1: The Problem Zone (Rio)
    c.customer_state = 'RJ'
    -- FILTER 2: Active Timeline (Post-2017 to capture relevant trends)
    AND o.order_purchase_timestamp >= '2017-01-01'
GROUP BY 
    p.product_id, 
    p.product_category_name
ORDER BY 
    -- PRIORITY: Volume (Stopping the highest number of complaints)
    total_orders_in_rio DESC
LIMIT 500;
"""

