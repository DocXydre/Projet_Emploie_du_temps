-- rejouable : ce fichier ne contient que des CREATE OR REPLACE ou des IF NOT
--             EXISTS. Le rejouer après modification est sans effet de bord.
-- =============================================================================
-- 008 — Trajets en train                                             (R63–R70)
-- =============================================================================
-- Aller à Saint-Dié suppose deux choses que le système connaît déjà : un creux
-- assez long dans l'emploi du temps, et une absence à déclarer au retour. Ce
-- fichier fait le lien entre les deux, et n'ajoute qu'une table — les horaires
-- viennent de la SNCF et ne se stockent que le temps d'être choisis.
--
-- Ce que le système ne fait pas : acheter le billet. Il propose des horaires et
-- gèle les tâches ménagères en conséquence. L'achat reste manuel, et une
-- proposition retenue n'est donc qu'une intention (R70).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Fenêtres de départ                                                 (R63, R64)
--
-- Une fenêtre est un creux d'au moins N heures sans cours ni travail. Le sommeil
-- n'en est pas un : dormir n'empêche pas d'être à Saint-Dié. Les absences déjà
-- déclarées sont retirées, sans quoi on proposerait un aller pour un week-end
-- où l'on est déjà parti.
--
-- L'arithmétique des multirange donne les bornes gratuitement : un creux
-- commence exactement quand finit l'obligation qui le précède, et finit quand
-- commence la suivante. Reste à distinguer une vraie borne du simple bord de
-- l'horizon interrogé — d'où les NULL, qui disent « rien ne t'attend de ce
-- côté-là » plutôt que d'inventer une contrainte.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fenetres_de_depart(
    p_utilisateur   INTEGER,
    p_debut         TIMESTAMPTZ,
    p_fin           TIMESTAMPTZ,
    p_duree_heures  INTEGER DEFAULT 48,
    p_marge_minutes INTEGER DEFAULT 30
) RETURNS TABLE (
    debut                 TIMESTAMPTZ,
    fin                   TIMESTAMPTZ,
    duree                 INTERVAL,
    fin_obligation_avant  TIMESTAMPTZ,
    debut_obligation_apres TIMESTAMPTZ,
    depart_au_plus_tot    TIMESTAMPTZ,
    retour_au_plus_tard   TIMESTAMPTZ
) LANGUAGE sql STABLE AS $$
    WITH horizon AS (
        SELECT tstzrange(greatest(p_debut, now()), p_fin, '[)') AS plage
    ),
    pris AS (
        -- Seuls les cours et le travail retiennent sur place. Une tâche
        -- ménagère, elle, se replace : ce n'est pas une raison de ne pas
        -- partir, c'est justement ce que l'absence résout.
        SELECT o.periode AS plage
          FROM occupation o, horizon h
         WHERE o.id_utilisateur = p_utilisateur
           AND o.type IN ('cours', 'travail')
           AND o.periode && h.plage

        UNION ALL

        SELECT a.periode
          FROM absence a, horizon h
         WHERE a.id_utilisateur = p_utilisateur
           AND a.periode && h.plage
    ),
    creux AS (
        SELECT unnest(
            tstzmultirange((SELECT plage FROM horizon))
            - COALESCE((SELECT range_agg(plage) FROM pris), '{}'::TSTZMULTIRANGE)
        ) AS plage
    )
    SELECT lower(c.plage),
           upper(c.plage),
           upper(c.plage) - lower(c.plage),
           -- Le bord de l'horizon n'est pas une obligation : ne rien affirmer
           -- vaut mieux qu'affirmer faux.
           CASE WHEN lower(c.plage) > (SELECT lower(plage) FROM horizon)
                THEN lower(c.plage) END,
           CASE WHEN upper(c.plage) < p_fin THEN upper(c.plage) END,
           -- R64 : le temps d'aller à la gare.
           CASE WHEN lower(c.plage) > (SELECT lower(plage) FROM horizon)
                THEN lower(c.plage) + make_interval(mins => p_marge_minutes)
                ELSE lower(c.plage) END,
           CASE WHEN upper(c.plage) < p_fin
                THEN upper(c.plage) - make_interval(mins => p_marge_minutes)
                ELSE upper(c.plage) END
      FROM creux c
     WHERE upper(c.plage) - lower(c.plage) >= make_interval(hours => p_duree_heures)
     ORDER BY lower(c.plage);
$$;

COMMENT ON FUNCTION fenetres_de_depart IS
    'Creux d''au moins N heures sans cours ni travail, avec les bornes '
    'utilisables pour chercher un train (R63, R64).';


-- -----------------------------------------------------------------------------
-- Table : Trajet                                                     (R65–R70)
--
-- R65 : les horaires ne sont pas des données du système. Ils appartiennent à
-- la SNCF, changent sans prévenir, et n'ont d'intérêt que le temps qu'on en
-- choisisse un. On ne les stocke donc que sous forme de propositions, avec un
-- statut qui dit ce qu'elles sont devenues.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trajet (
    id_trajet       BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    id_utilisateur  INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur)
                                 ON DELETE CASCADE,
    sens            VARCHAR(10)  NOT NULL CHECK (sens IN ('aller', 'retour')),
    periode         TSTZRANGE    NOT NULL CHECK (NOT isempty(periode)
                                                 AND lower(periode) IS NOT NULL
                                                 AND upper(periode) IS NOT NULL),
    origine         VARCHAR(100) NOT NULL,
    destination     VARCHAR(100) NOT NULL,
    correspondances SMALLINT     NOT NULL DEFAULT 0 CHECK (correspondances >= 0),
    resume          VARCHAR(200),
    statut          VARCHAR(20)  NOT NULL DEFAULT 'proposee'
                                 CHECK (statut IN ('proposee', 'retenue', 'ecartee')),
    -- Un retour se rattache à son aller : c'est ce qui permet de ne proposer
    -- que des retours postérieurs à l'arrivée, et de solder la série d'un coup.
    id_trajet_aller BIGINT       REFERENCES trajet (id_trajet) ON DELETE CASCADE,
    id_absence      INTEGER      REFERENCES absence (id_absence) ON DELETE SET NULL,
    date_creation   TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT trajet_retour_rattache CHECK (sens = 'retour' OR id_trajet_aller IS NULL)
);

CREATE INDEX IF NOT EXISTS trajet_par_utilisateur
    ON trajet (id_utilisateur, statut, lower(periode));

COMMENT ON TABLE trajet IS
    'Propositions d''horaires. Retenir un aller et un retour crée l''absence '
    'correspondante ; le billet, lui, s''achète ailleurs (R70).';


-- Rien ici n'interdit de retenir deux fois le même week-end : c'est la
-- contrainte d'exclusion sur `absence` qui s'en charge, puisque retenir crée
-- une absence. Dupliquer la règle ici la ferait diverger un jour.


-- -----------------------------------------------------------------------------
-- Vue : propositions encore valables
--
-- Une proposition dont le train est parti n'est plus une proposition. Plutôt
-- que de faire tourner un nettoyage, on la laisse en base et la vue cesse de
-- la montrer : l'historique reste lisible, et rien ne dépend d'un balayage.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_trajet AS
SELECT t.id_trajet,
       t.id_utilisateur,
       u.pseudo,
       t.sens,
       lower(t.periode)                                   AS depart,
       upper(t.periode)                                   AS arrivee,
       upper(t.periode) - lower(t.periode)                AS duree,
       t.origine,
       t.destination,
       t.correspondances,
       t.resume,
       t.statut,
       t.id_trajet_aller,
       t.id_absence,
       (t.statut = 'proposee' AND lower(t.periode) > now()) AS encore_valable
  FROM trajet t
  JOIN utilisateur u ON u.id_utilisateur = t.id_utilisateur;


-- -----------------------------------------------------------------------------
-- Retenir un trajet                                                  (R67–R69)
--
-- Le geste central : choisir des horaires devient une absence, donc un planning
-- ménager qui se refait tout seul. C'est la seule raison d'être de la table.
--
-- Le retour peut manquer. Partir sans savoir quand on rentre est un cas
-- ordinaire, et refuser de l'enregistrer obligerait à choisir un horaire au
-- hasard pour contenter le modèle. L'absence court alors jusqu'à la prochaine
-- obligation connue (R69).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retenir_trajet(
    p_aller  BIGINT,
    p_retour BIGINT DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_aller     trajet;
    v_retour    trajet;
    v_fin       TIMESTAMPTZ;
    v_absence   INTEGER;
    v_commentaire TEXT;
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
        v_commentaire := 'Aller ' || to_char(lower(v_aller.periode) AT TIME ZONE 'Europe/Paris',
                                             'DD/MM HH24"h"MI')
                      || ', retour ' || to_char(upper(v_retour.periode) AT TIME ZONE 'Europe/Paris',
                                                'DD/MM HH24"h"MI');
    ELSE
        -- R69 : sans retour choisi, l'absence court jusqu'à ce qui nous rappelle.
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

    INSERT INTO absence (id_utilisateur, periode, lieu, origine, commentaire)
    VALUES (v_aller.id_utilisateur,
            tstzrange(lower(v_aller.periode), v_fin, '[)'),
            v_aller.destination, 'trajet', v_commentaire)
    RETURNING id_absence INTO v_absence;

    UPDATE trajet
       SET statut = 'retenue', id_absence = v_absence
     WHERE id_trajet IN (p_aller, p_retour);

    -- R68 : les autres horaires du même choix n'ont plus lieu d'être. On les
    -- écarte plutôt que de les supprimer : relire ce qui avait été proposé
    -- aide à comprendre un choix, six mois plus tard.
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
    'Transforme des horaires choisis en absence déclarée (R67). Le retour peut '
    'manquer : l''absence court alors jusqu''à la prochaine obligation (R69).';
