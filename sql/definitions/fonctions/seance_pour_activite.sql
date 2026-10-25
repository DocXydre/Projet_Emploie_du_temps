-- -----------------------------------------------------------------------------
-- La séance qu'une activité de la montre vient remplir            (SAN-4, SAN-9)
--
-- Même compte, même jour, séance de sport encore ouverte ou close comme pas
-- faite, sans activité déjà rattachée. Une séance du coach a sa discipline.
-- Une séance posée à la main n'en a pas (SPT-17) : elle convient si son lieu
-- sert à cette discipline pour ce compte, ou si elle n'a pas de lieu. La plus
-- proche en heure l'emporte, une discipline sûre avant une discipline déduite.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seance_pour_activite(p_utilisateur INTEGER, p_discipline TEXT,
                                               p_debut TIMESTAMPTZ)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT o.id_occurrence
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache AND t.categorie = 'sport'
      LEFT JOIN seance se ON se.id_occurrence = o.id_occurrence
     WHERE o.id_utilisateur = p_utilisateur
       AND o.origine <> 'quota'
       AND jour_de(COALESCE(o.debut_seance, lower(o.creneau), lower(o.fenetre)))
           = jour_de(p_debut)
       AND (o.statut IN ('a_placer', 'planifiee', 'notifiee', 'faite')
            OR (o.statut = 'abandonnee' AND o.motif = 'Pas faite'))
       AND NOT EXISTS (SELECT 1 FROM activite_sante x WHERE x.id_occurrence = o.id_occurrence)
       AND (se.discipline = p_discipline
            OR (se.id_occurrence IS NULL
                AND (o.id_lieu IS NULL
                     OR EXISTS (SELECT 1 FROM lieux_de_sport(p_utilisateur) dl
                                 WHERE dl.id_lieu = o.id_lieu
                                   AND dl.discipline = p_discipline))))
     ORDER BY (se.discipline IS NULL),
              abs(EXTRACT(EPOCH FROM (COALESCE(o.debut_seance, lower(o.creneau),
                                               lower(o.fenetre)) - p_debut)))
     LIMIT 1
$$;

COMMENT ON FUNCTION seance_pour_activite(INTEGER, TEXT, TIMESTAMPTZ) IS
    'SAN-4, SAN-9 : la séance du même jour qu''une activité de la montre vient
     remplir, séances posées à la main comprises (par le lieu de la discipline).';
