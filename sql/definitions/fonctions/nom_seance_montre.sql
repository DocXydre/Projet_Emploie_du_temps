-- -----------------------------------------------------------------------------
-- Le nom d'une séance de la montre, en français                        (SAN-4)
--
-- La montre donne un type brut (« running », « HKWorkoutActivityTypeRunning »).
-- La séance libre qui en naît prend le même nom que l'écran Santé de l'appli
-- (`TypesSeance.nom`, ios/HAL/HAL/Sante/LecteurSante.swift), avec une
-- majuscule comme les types de séance du coach. Un type inconnu ne donne
-- rien : la séance s'appelle alors par sa discipline.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nom_seance_montre(p_type VARCHAR, p_interieur BOOLEAN)
RETURNS VARCHAR LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE regexp_replace(replace(lower(COALESCE(p_type, '')),
                                       'hkworkoutactivitytype', ''), '[^a-z0-9]', '', 'g')
        WHEN 'running' THEN CASE WHEN p_interieur THEN 'Course sur tapis' ELSE 'Course' END
        WHEN 'trailrunning' THEN 'Trail'
        WHEN 'traditionalstrengthtraining' THEN 'Musculation'
        WHEN 'functionalstrengthtraining' THEN 'Renforcement fonctionnel'
        WHEN 'coretraining' THEN 'Gainage'
        WHEN 'highintensityintervaltraining' THEN 'HIIT'
        WHEN 'elliptical' THEN 'Elliptique'
        WHEN 'rowing' THEN 'Rameur'
        WHEN 'stairclimbing' THEN 'Escaliers'
        WHEN 'stairs' THEN 'Escaliers'
        WHEN 'stepper' THEN 'Stepper'
        WHEN 'steptraining' THEN 'Stepper'
        WHEN 'indoorcycling' THEN 'Vélo d''intérieur'
        WHEN 'cycling' THEN CASE WHEN p_interieur THEN 'Vélo d''intérieur' ELSE 'Vélo' END
        WHEN 'mixedcardio' THEN 'Cardio'
        WHEN 'crosstraining' THEN 'Cross training'
        WHEN 'skierg' THEN 'Ski erg'
        WHEN 'swimming' THEN 'Natation'
        WHEN 'walking' THEN 'Marche'
        WHEN 'hiking' THEN 'Randonnée'
        WHEN 'yoga' THEN 'Yoga'
        WHEN 'flexibility' THEN 'Souplesse'
        WHEN 'cooldown' THEN 'Retour au calme'
    END;
$$;

COMMENT ON FUNCTION nom_seance_montre(VARCHAR, BOOLEAN) IS
    'SAN-4 : le nom français d''une séance de la montre, d''après son type brut
     et le fait qu''elle se soit faite en intérieur. Le même que l''écran Santé
     de l''appli. NULL pour un type inconnu.';
