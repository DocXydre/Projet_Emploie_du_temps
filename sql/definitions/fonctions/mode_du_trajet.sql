-- -----------------------------------------------------------------------------
-- Le mode d'un trajet, d'un lieu à un autre                            (ADR-7)
--
-- Celui du lieu d'arrivée, dit par le compte. Mais personne ne va à pied à une
-- salle à 80 km : au-delà de 5 km à vol d'oiseau à pied, ou de 20 km à vélo, le
-- trajet se compte en voiture. Depuis Lusse, on prend la voiture.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mode_du_trajet(p_utilisateur INTEGER, p_depart INTEGER,
                                          p_arrivee INTEGER)
RETURNS VARCHAR LANGUAGE sql STABLE AS $$
    SELECT CASE
             WHEN m.mode = 'pied' AND x.d > 5000 THEN 'voiture'
             WHEN m.mode = 'velo' AND x.d > 20000 THEN 'voiture'
             ELSE m.mode
           END
      FROM (SELECT mode_trajet_de(p_utilisateur, p_arrivee) AS mode) m,
           LATERAL (SELECT distance_m(d.latitude, d.longitude, a.latitude, a.longitude) AS d
                      FROM lieu_connu d, lieu_connu a
                     WHERE d.id_lieu_connu = p_depart AND a.id_lieu_connu = p_arrivee) x;
$$;

COMMENT ON FUNCTION mode_du_trajet(INTEGER, INTEGER, INTEGER) IS
    'ADR-7 : le mode du lieu d''arrivée ; en voiture au-delà de 5 km à pied ou de 20 km à vélo.';
