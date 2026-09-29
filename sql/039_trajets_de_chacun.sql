-- rejouable : ce fichier ne contient que des ALTER ... IF NOT EXISTS, des
--             CREATE OR REPLACE et des mises à jour idempotentes.
-- =============================================================================
-- 039 : les trajets de chacun                                 (TRJ-8 à TRJ-11)
--
-- Quatre choses que l'usage à deux a mises au jour.
--
-- La destination n'est pas la même pour tout le monde. Thomas rentre à Lusse et
-- descend à Saint-Dié ; Lorette va à Saint-Dié tout court. Le lieu était écrit
-- une fois pour toutes dans le .env, donc faux pour l'une des deux.
--
-- Tous les voyages comptent, pas seulement ceux vers la famille. Un billet pour
-- Paris est un billet : il doit se dire, et geler ce qu'il faut geler.
--
-- Un aller-retour dans la journée n'est pas une absence. On n'est pas là
-- l'après-midi, mais on dort chez soi et la vaisselle du soir reste à faire.
-- Il se signale quand même : c'est une journée qui saute.
--
-- Et un train pris se voit dans le planning. Il peut tomber sur un cours qu'on
-- manque volontairement : ce n'est pas au système d'en juger, seulement de
-- l'afficher.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Chacun sa destination                                              (TRJ-8)
--
-- NULL suit le .env, comme avant. C'est la valeur de celui qui a installé le
-- système, et elle reste juste pour lui.
-- -----------------------------------------------------------------------------
ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS lieu_famille VARCHAR(60);
ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS gare_famille VARCHAR(40);

COMMENT ON COLUMN utilisateur.lieu_famille IS
    'Le lieu tel qu''on le nomme : « Lusse » pour l''un, « Saint-Dié » pour
     l''autre. NULL suit la configuration du serveur (TRJ-8).';

COMMENT ON COLUMN utilisateur.gare_famille IS
    'La gare où l''on descend, par son code interne. NULL suit la
     configuration du serveur (TRJ-8).';

-- Lorette va à Saint-Dié, pas à Lusse. Par une fonction, et non par un UPDATE
-- direct : les comptes n'existent pas forcément au moment des migrations, et
-- l'API rejoue ceci à chaque démarrage, comme les assignations (COL-16).
CREATE OR REPLACE FUNCTION appliquer_destinations() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_touchees INTEGER;
BEGIN
    UPDATE utilisateur
       SET lieu_famille = 'Saint-Dié', gare_famille = 'SAINT_DIE'
     WHERE pseudo = 'lorette'
       AND lieu_famille IS NULL
       AND gare_famille IS NULL;

    GET DIAGNOSTICS v_touchees = ROW_COUNT;
    RETURN v_touchees;
END $$;

COMMENT ON FUNCTION appliquer_destinations IS
    'Pose les destinations connues sur les comptes qui n''en ont pas. Rejouée
     au démarrage, elle rattrape les comptes créés après la migration (TRJ-8).';

SELECT appliquer_destinations();


-- -----------------------------------------------------------------------------
-- 2. Un train se voit dans le planning                                 (TRJ-11)
--
-- Le trajet devient une occupation de type « autre » : elle s'affiche, elle
-- compte pour le placement des tâches, et elle échappe à la contrainte de
-- non-chevauchement (COL-15). Un train qui recouvre un cours est donc accepté,
-- c'est un choix qu'on a le droit de faire.
--
-- La clé externe porte l'identifiant du trajet : reposer le même trajet ne crée
-- pas de doublon, et l'annuler retire exactement la bonne ligne.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION poser_trajet_au_planning(p_trajet BIGINT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    t        trajet;
    v_source INTEGER;
    v_ligne  INTEGER;
BEGIN
    SELECT * INTO t FROM trajet WHERE id_trajet = p_trajet;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT id_source INTO v_source FROM source WHERE code = 'MANUELLE';

    INSERT INTO occupation (id_utilisateur, id_source, type, libelle, lieu,
                            periode, cle_externe, details)
    VALUES (t.id_utilisateur, v_source, 'autre',
            format('Train %s → %s', t.origine, t.destination),
            t.destination, t.periode, format('trajet-%s', t.id_trajet),
            COALESCE(t.resume, 'Billet'))
    -- L'unicité porte sur (source, clé) : c'est elle qu'on vise.
    ON CONFLICT (id_source, cle_externe) DO UPDATE
       SET periode = EXCLUDED.periode,
           libelle = EXCLUDED.libelle,
           lieu    = EXCLUDED.lieu
    RETURNING id_occupation INTO v_ligne;

    RETURN v_ligne;
END $$;

COMMENT ON FUNCTION poser_trajet_au_planning IS
    'Affiche un train retenu dans le planning, en occupation « autre » : elle
     peut chevaucher un cours, c''est un choix assumé (TRJ-11).';


CREATE OR REPLACE FUNCTION retirer_trajet_du_planning(p_trajet BIGINT)
RETURNS INTEGER LANGUAGE sql AS $$
    WITH parties AS (
        DELETE FROM occupation
         WHERE cle_externe = format('trajet-%s', p_trajet)
           AND id_source = (SELECT id_source FROM source WHERE code = 'MANUELLE')
        RETURNING 1)
    SELECT count(*)::INTEGER FROM parties;
$$;


-- -----------------------------------------------------------------------------
-- 3. Retenir un trajet                                        (TRJ-9 à TRJ-11)
--
-- Ce qui change : l'absence n'est déclarée que si le voyage passe une nuit
-- dehors. Un aller-retour dans la journée laisse la journée occupée par les
-- trains, sans geler les tâches du soir.
--
-- La fonction rend l'identifiant de l'absence, ou NULL quand il n'y en a pas
-- besoin. L'appelant n'a donc plus à supposer qu'une absence existe.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retenir_trajet(
    p_aller  BIGINT,
    p_retour BIGINT DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_aller       trajet;
    v_retour      trajet;
    v_fin         TIMESTAMPTZ;
    v_absence     INTEGER;
    v_commentaire TEXT;
    v_meme_jour   BOOLEAN := FALSE;
BEGIN
    SELECT * INTO v_aller FROM trajet WHERE id_trajet = p_aller AND sens = 'aller';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Aller % introuvable', p_aller
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_retour IS NOT NULL THEN
        SELECT * INTO v_retour FROM trajet WHERE id_trajet = p_retour AND sens = 'retour';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Retour % introuvable', p_retour
                USING ERRCODE = 'no_data_found';
        END IF;

        IF lower(v_retour.periode) < upper(v_aller.periode) THEN
            RAISE EXCEPTION 'Le retour part avant l''arrivée de l''aller'
                USING ERRCODE = 'check_violation';
        END IF;

        v_fin := upper(v_retour.periode);
        v_meme_jour := jour_de(upper(v_retour.periode)) = jour_de(lower(v_aller.periode));
        v_commentaire := 'Aller ' || to_char(lower(v_aller.periode) AT TIME ZONE 'Europe/Paris',
                                             'DD/MM HH24"h"MI')
                      || ', retour ' || to_char(upper(v_retour.periode) AT TIME ZONE 'Europe/Paris',
                                                'DD/MM HH24"h"MI');
    ELSE
        -- TRJ-7 : sans retour choisi, l'absence court jusqu'à ce qui nous rappelle.
        SELECT f.fin INTO v_fin
          FROM fenetres_de_depart(v_aller.id_utilisateur,
                                  lower(v_aller.periode) - INTERVAL '1 hour',
                                  lower(v_aller.periode) + INTERVAL '30 days',
                                  1) f
         ORDER BY f.debut
         LIMIT 1;

        v_fin := COALESCE(v_fin, upper(v_aller.periode) + INTERVAL '2 days');
        v_commentaire := 'Aller ' || to_char(lower(v_aller.periode) AT TIME ZONE 'Europe/Paris',
                                             'DD/MM HH24"h"MI') || ', retour à fixer';
    END IF;

    -- TRJ-11 : les trains s'affichent, qu'il y ait absence ou non.
    PERFORM poser_trajet_au_planning(p_aller);
    IF p_retour IS NOT NULL THEN
        PERFORM poser_trajet_au_planning(p_retour);
    END IF;

    -- TRJ-10 : parti et revenu le même jour, on dort chez soi. Les tâches du
    -- soir restent dues, seuls les trains occupent la journée.
    IF v_meme_jour THEN
        UPDATE trajet SET statut = 'retenue' WHERE id_trajet IN (p_aller, p_retour);
        RETURN NULL;
    END IF;

    INSERT INTO absence (id_utilisateur, periode, lieu, origine, commentaire)
    VALUES (v_aller.id_utilisateur,
            tstzrange(lower(v_aller.periode), v_fin, '[)'),
            v_aller.destination, 'trajet', v_commentaire)
    RETURNING id_absence INTO v_absence;

    UPDATE trajet
       SET statut = 'retenue', id_absence = v_absence
     WHERE id_trajet IN (p_aller, p_retour);

    -- TRJ-6 : les autres horaires proposés passent en « écartée ». On les
    -- garde en base pour pouvoir relire ce qui avait été proposé.
    UPDATE trajet
       SET statut = 'ecartee'
     WHERE statut = 'proposee'
       AND id_utilisateur = v_aller.id_utilisateur
       AND (id_trajet_aller = p_aller
            OR (sens = 'aller'
                AND lower(periode) BETWEEN lower(v_aller.periode) - INTERVAL '2 days'
                                       AND lower(v_aller.periode) + INTERVAL '2 days'));

    RETURN v_absence;
END $$;

COMMENT ON FUNCTION retenir_trajet IS
    'Transforme des horaires choisis en trains affichés, et en absence si le
     voyage passe une nuit dehors (TRJ-5, TRJ-10, TRJ-11). Rend NULL pour un
     aller-retour dans la journée.';


-- -----------------------------------------------------------------------------
-- 4. Oublier un trajet                                                 (TRJ-11)
--
-- Annuler doit tout retirer : l'absence, et les trains posés au planning.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION oublier_trajet(p_absence INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    t       RECORD;
    v_n     INTEGER := 0;
BEGIN
    FOR t IN SELECT id_trajet FROM trajet WHERE id_absence = p_absence LOOP
        v_n := v_n + COALESCE(retirer_trajet_du_planning(t.id_trajet), 0);
    END LOOP;

    UPDATE trajet SET statut = 'ecartee', id_absence = NULL
     WHERE id_absence = p_absence;

    DELETE FROM absence WHERE id_absence = p_absence;
    RETURN v_n;
END $$;

COMMENT ON FUNCTION oublier_trajet IS
    'Annule une absence issue d''un billet : l''absence part, et les trains
     quittent le planning avec elle (TRJ-11).';
