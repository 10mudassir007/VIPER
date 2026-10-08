-- ============================================================
-- SEED DATA — run once, after 001_schema.sql, on an empty database.
-- Sample data only. Do not load into production with real stock.
-- ============================================================


-- The single robot. Must exist before any robot function is called.
INSERT INTO public.robot (robot_id, robot_name, model, status)
VALUES (1, 'PHARMA-BOT-01', 'Pick-and-place v1', 'OFFLINE')
ON CONFLICT (robot_id) DO NOTHING;


INSERT INTO public.medicines (name, generic_name, brand_name, strength, dosage_form,
                              manufacturer, barcode, requires_prescription)
VALUES
    ('Amoxicillin 500mg Capsule', 'Amoxicillin', 'Amoxil', '500mg', 'Capsule',
     'Example Pharma', '890100000001', TRUE),
    ('Paracetamol 500mg Tablet', 'Paracetamol', 'Panadol', '500mg', 'Tablet',
     'Example Pharma', '890100000002', FALSE),
    ('Ibuprofen 400mg Tablet', 'Ibuprofen', 'Brufen', '400mg', 'Tablet',
     'Example Pharma', '890100000003', FALSE);


-- Coordinates are placeholders; measure the real floor.
INSERT INTO public.racks (rack_number, zone, x_coordinate, y_coordinate, orientation_degrees)
VALUES
    ('RACK-01', 'A', 2.50, 4.00, 0),
    ('RACK-02', 'A', 6.20, 4.00, 0),
    ('RACK-03', 'B', 9.80, 4.00, 180);


-- Four shelves per rack; heights in cm from the floor.
INSERT INTO public.shelves (rack_id, shelf_number, height_cm, width_cm, depth_cm)
SELECT r.rack_id, s.shelf_number, s.height_cm, 100, 40
FROM public.racks r
CROSS JOIN (VALUES (1, 40), (2, 75), (3, 110), (4, 145))
     AS s(shelf_number, height_cm);


-- One sample bin: Amoxicillin on RACK-01, shelf 3, bin B2.
INSERT INTO public.inventory (medicine_id, shelf_id, bin_code, batch_number,
                              quantity, low_stock_threshold, expiry_date)
SELECT m.medicine_id, s.shelf_id, 'B2', 'AMX-2026-04', 37, 5, DATE '2027-04-30'
FROM public.medicines m
JOIN public.racks r ON r.rack_number = 'RACK-01'
JOIN public.shelves s ON s.rack_id = r.rack_id AND s.shelf_number = 3
WHERE m.barcode = '890100000001';


-- ============================================================
-- END OF SEED
-- ============================================================