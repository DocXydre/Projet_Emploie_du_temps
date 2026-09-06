-- rejouable : ADD COLUMN IF NOT EXISTS, UPDATE et CREATE OR REPLACE.
-- =============================================================================
-- 018 : relever les horaires au lieu de les saisir            (SPT-14, SPT-15)
--
-- Le SUAPS change ses créneaux d'une semaine à l'autre. Une saisie à la main
-- est fausse dès le lundi suivant, et personne ne s'en aperçoit avant de
-- trouver porte close.
--
-- Un lieu peut donc déclarer d'où viennent ses horaires. Le relevé remplace ses
-- ouvertures, et seulement les siennes.
-- =============================================================================

-- SPT-14 : la page publique où le lieu publie ses créneaux. NULL pour un lieu
-- dont les horaires se saisissent à la main, comme la salle.
ALTER TABLE lieu_sport ADD COLUMN IF NOT EXISTS url_horaires TEXT;

-- Filtres du relevé : la page liste plusieurs sites et plusieurs publics.
--   site    : nom du lieu tel que la page l'écrit
--   publics : publics acceptés, en minuscules
ALTER TABLE lieu_sport ADD COLUMN IF NOT EXISTS configuration JSONB
    NOT NULL DEFAULT '{}'::JSONB;

ALTER TABLE lieu_sport ADD COLUMN IF NOT EXISTS horaires_releves_le TIMESTAMPTZ;

COMMENT ON COLUMN lieu_sport.url_horaires IS
    'Page publique d''où les créneaux sont relevés. NULL : saisie manuelle
     (SPT-14).';

COMMENT ON COLUMN lieu_sport.horaires_releves_le IS
    'Dernier relevé réussi. Au-delà de quelques jours, les horaires affichés
     sont à prendre avec précaution (SPT-15).';


UPDATE lieu_sport
   SET url_horaires = 'https://sport.univ-lorraine.fr/activites-aquatiques/'
                      '139-1088-natation-pratique-libre-ouverte-a-tous.html',
       configuration = '{
           "site": "Piscine universitaire des Océanautes",
           "publics": ["tout public", "étudiant"]
       }'::JSONB
 WHERE code = 'PISCINE_SUAPS';


-- -----------------------------------------------------------------------------
-- Remplacer les ouvertures d'un lieu                                    (SPT-15)
--
-- Le remplacement est en bloc : un créneau supprimé à la source doit
-- disparaître d'ici, sinon le moteur proposerait une séance devant une porte
-- close.
--
-- Mais une liste vide ne remplace rien. C'est la leçon du planning de travail :
-- une collecte muette avait effacé deux semaines de services. Une page qui ne
-- répond plus, une refonte du site, une session expirée — dans tous ces cas on
-- garde ce qu'on avait et on le signale.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION remplacer_ouvertures(
    p_code      VARCHAR,
    p_creneaux  JSONB
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_lieu   INTEGER;
    v_nombre INTEGER;
BEGIN
    SELECT id_lieu INTO v_lieu FROM lieu_sport WHERE code = p_code;
    IF v_lieu IS NULL THEN
        RAISE EXCEPTION 'Lieu % inconnu', p_code USING ERRCODE = 'no_data_found';
    END IF;

    v_nombre := jsonb_array_length(COALESCE(p_creneaux, '[]'::JSONB));
    IF v_nombre = 0 THEN
        RAISE EXCEPTION 'Relevé vide : les horaires existants sont conservés'
              USING ERRCODE = 'no_data_found';
    END IF;

    DELETE FROM ouverture WHERE id_lieu = v_lieu;

    INSERT INTO ouverture (id_lieu, jour_semaine, heure_debut, heure_fin)
    SELECT v_lieu,
           (c ->> 'jour')::SMALLINT,
           (c ->> 'debut')::TIME,
           (c ->> 'fin')::TIME
      FROM jsonb_array_elements(p_creneaux) c
    ON CONFLICT (id_lieu, jour_semaine, heure_debut) DO NOTHING;

    UPDATE lieu_sport
       SET horaires_releves_le = now()
     WHERE id_lieu = v_lieu;

    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION remplacer_ouvertures IS
    'Remplace en bloc les créneaux d''ouverture d''un lieu. Refuse une liste
     vide plutôt que de tout effacer (SPT-15).';


-- -----------------------------------------------------------------------------
-- Lieux à relever
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_lieu_a_relever AS
SELECT id_lieu, code, libelle, url_horaires, configuration,
       horaires_releves_le,
       (SELECT count(*) FROM ouverture o WHERE o.id_lieu = l.id_lieu) AS creneaux,
       horaires_releves_le IS NULL
       OR horaires_releves_le < now() - INTERVAL '2 days' AS a_relever
  FROM lieu_sport l
 WHERE url_horaires IS NOT NULL;
