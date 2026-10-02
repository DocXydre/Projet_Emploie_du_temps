-- rejouable : ce fichier ne contient que des CREATE OR REPLACE et un DROP VIEW
--             suivi de sa recréation.
-- =============================================================================
-- 046 : le week-end se voit avant de se dire                   (WKD-7, WKD-8)
--
-- Deux corrections sur les propositions, et elles vont dans le même sens :
-- moins de bruit, et des dates justes.
--
-- Le repérage et l'annonce étaient le même geste. Un creux repéré quinze jours
-- avant déclenchait une notification quinze jours avant, puis une relance : à
-- raison de deux week-ends dans la fenêtre, cela fait quatre messages pour une
-- question qui ne se pose vraiment qu'à une semaine. On sépare donc les deux.
-- La proposition s'inscrit au calendrier dès qu'elle est repérée, en silence ;
-- la notification attend d'être à portée d'achat de billet.
--
-- Et un week-end confirmé s'affichait sur la fenêtre libre repérée, pas sur le
-- voyage réel. Le train du retour partait le dimanche matin, le calendrier
-- gardait le lundi en week-end. Un billet en main vaut mieux qu'un creux.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Les propositions qui attendent leur annonce                        (WKD-7)
--
-- Repérées, inscrites au calendrier, mais encore muettes. Elles le restent
-- jusqu'à ce que le départ entre dans le délai d'annonce.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION propositions_a_annoncer(
    p_jours INTEGER DEFAULT 7
) RETURNS SETOF proposition LANGUAGE sql STABLE AS $$
    SELECT *
      FROM proposition
     WHERE statut = 'proposee'
       AND annoncee_le IS NULL
       AND lower(periode) <= now() + make_interval(days => p_jours)
       -- Un week-end commencé n'est plus une proposition.
       AND upper(periode) > now()
     ORDER BY lower(periode);
$$;

COMMENT ON FUNCTION propositions_a_annoncer IS
    'Propositions déjà au calendrier mais jamais annoncées, dont le départ
     entre dans le délai : c''est là qu''on en parle (WKD-7).';


-- -----------------------------------------------------------------------------
-- 2. Un week-end confirmé s'affiche sur le voyage, pas sur le creux     (WKD-8)
--
-- La période retenue est l'intersection de la proposition et de l'absence qui
-- la couvre. Calculée dans la vue et non stockée : si le retour change, par un
-- billet raccordé ou un trajet annulé, le calendrier suit sans rien à rejouer.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_planning;

CREATE VIEW v_planning AS
SELECT
    'occupation'                       AS nature,
    o.id_occupation::BIGINT            AS id,
    o.id_utilisateur,
    o.type                             AS categorie,
    o.libelle,
    o.periode,
    lower(o.periode)                   AS debut,
    upper(o.periode)                   AS fin,
    FALSE                              AS journee_entiere,
    NULL::VARCHAR                      AS statut,
    o.lieu,
    o.details                          AS motif,
    0                                  AS nb_relances
FROM occupation o

UNION ALL

SELECT
    'tache'                            AS nature,
    o.id_occurrence::BIGINT            AS id,
    o.id_utilisateur,
    t.categorie,
    CASE WHEN o.origine = 'quota' THEN t.libelle || ' à déterminer'
         ELSE t.libelle END            AS libelle,
    o.creneau                          AS periode,
    lower(o.creneau)                   AS debut,
    upper(o.creneau)                   AS fin,
    o.rappel_journee                   AS journee_entiere,
    o.statut,
    CASE WHEN o.origine = 'quota' THEN NULL ELSE l.libelle END AS lieu,
    o.motif,
    o.nb_relances
FROM occurrence o
JOIN tache t ON t.id_tache = o.id_tache
LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
WHERE o.creneau IS NOT NULL
  AND o.statut IN ('planifiee', 'notifiee')

UNION ALL

-- WKD-1 : une proposition n'occupe rien et ne gèle rien. Elle s'affiche pour
-- qu'on y pense, et cesse de poser la question dès qu'on a répondu.
-- WKD-6 : une fois le voyage confirmé, elle reste, sans point d'interrogation.
-- WKD-8 : et sur les dates du voyage, pas sur celles du creux repéré.
SELECT
    'proposition'                      AS nature,
    p.id_proposition                   AS id,
    p.id_utilisateur,
    CASE WHEN p.statut = 'realisee' THEN 'weekend' ELSE 'trajet' END AS categorie,
    CASE WHEN p.statut = 'realisee'
         THEN 'Week-end' || COALESCE(' à ' || p.lieu, '')
         ELSE 'Week-end libre' || COALESCE(' à ' || p.lieu, '') || ' ?'
    END                                AS libelle,
    COALESCE(p.periode * a.periode, p.periode)         AS periode,
    lower(COALESCE(p.periode * a.periode, p.periode))  AS debut,
    upper(COALESCE(p.periode * a.periode, p.periode))  AS fin,
    TRUE                               AS journee_entiere,
    p.statut,
    p.lieu,
    CASE WHEN p.statut = 'realisee'
         THEN 'Confirmé : une absence couvre ce week-end'
         ELSE 'Repéré par le système : aucune obligation sur cette période'
    END                                AS motif,
    0                                  AS nb_relances
FROM proposition p
LEFT JOIN LATERAL (
    SELECT ab.periode
      FROM absence ab
     WHERE p.statut = 'realisee'
       AND ab.id_utilisateur = p.id_utilisateur
       AND ab.periode && p.periode
     ORDER BY lower(ab.periode)
     LIMIT 1
) a ON TRUE
WHERE p.statut IN ('proposee', 'realisee');

COMMENT ON VIEW v_planning IS
    'Occupations, tâches placées et propositions dans une seule vue. Le drapeau
     journee_entiere décide si l''export produit un VEVENT horaire ou un
     VEVENT journée entière (NOT-3). Une réservation de sport s''y lit « à
     déterminer », sans lieu (SPT-18). Une proposition réalisée s''y lit
     « Week-end à ... », sur les dates du voyage (WKD-6, WKD-8).';
