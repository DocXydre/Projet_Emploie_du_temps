CREATE OR REPLACE FUNCTION planning_filtre(
    p_personnes INTEGER[],
    p_contenus  TEXT[],
    p_debut     TIMESTAMPTZ,
    p_fin       TIMESTAMPTZ)
RETURNS TABLE (
    nature          TEXT,
    id              BIGINT,
    id_utilisateur  INTEGER,
    qui             TEXT,
    contenu         TEXT,
    categorie       TEXT,
    libelle         TEXT,
    debut           TIMESTAMPTZ,
    fin             TIMESTAMPTZ,
    journee_entiere BOOLEAN,
    statut          TEXT,
    lieu            TEXT,
    motif           TEXT,
    nb_relances     INTEGER)
LANGUAGE sql STABLE AS $$
    SELECT p.nature::TEXT, p.id, p.id_utilisateur, u.nom::TEXT,
           contenu_de(p.nature::TEXT, p.categorie::TEXT),
           p.categorie::TEXT, p.libelle::TEXT, p.debut, p.fin,
           p.journee_entiere, p.statut::TEXT, p.lieu::TEXT, p.motif::TEXT,
           p.nb_relances
      FROM v_planning p
      JOIN utilisateur u ON u.id_utilisateur = p.id_utilisateur
     WHERE p.id_utilisateur = ANY (p_personnes)
       AND p.debut < p_fin
       AND p.fin   > p_debut
       AND contenu_de(p.nature::TEXT, p.categorie::TEXT) = ANY (p_contenus)
     ORDER BY p.debut, u.nom;
$$;

COMMENT ON FUNCTION planning_filtre IS
    'Le planning des personnes demandées, réduit aux familles de contenu
     demandées (NOT-6).';
