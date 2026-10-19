-- -----------------------------------------------------------------------------
-- Une séance vient-elle de la montre ?                                  (SAN-15)
--
-- L'appli envoie l'appareil (« Watch ») et la source (« Apple Watch de
-- Thomas ») dans `details`. L'un ou l'autre suffit.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION activite_de_la_montre(p_details JSONB)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(p_details ->> 'appareil' ILIKE '%watch%', FALSE)
        OR COALESCE(p_details ->> 'source' ILIKE '%watch%', FALSE)
$$;

COMMENT ON FUNCTION activite_de_la_montre(JSONB) IS
    'SAN-15 : vrai si la séance a été enregistrée par une Apple Watch, d''après
     l''appareil ou la source que l''appli a lus dans Santé.';
