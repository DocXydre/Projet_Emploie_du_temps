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
    -- TAC-16 : le titre de l'occurrence quand elle en accompagne une autre.
    CASE WHEN o.origine = 'quota' THEN t.libelle || ' à déterminer'
         ELSE COALESCE(o.titre, t.libelle) END AS libelle,
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
