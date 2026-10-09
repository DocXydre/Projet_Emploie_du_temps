CREATE VIEW v_cout_coach AS
SELECT a.id_utilisateur,
       jour_de(a.debut)                                   AS jour,
       a.moment,
       a.modele,
       count(*)::INTEGER                                  AS appels,
       count(*) FILTER (WHERE a.statut = 'echoue')::INTEGER AS echecs,
       sum(a.tours)::INTEGER                              AS tours,
       sum(a.tokens_entree)::BIGINT                       AS tokens_entree,
       sum(a.tokens_cache)::BIGINT                        AS tokens_cache,
       sum(a.tokens_sortie)::BIGINT                       AS tokens_sortie
  FROM appel_coach a
 GROUP BY a.id_utilisateur, jour_de(a.debut), a.moment, a.modele;

COMMENT ON VIEW v_cout_coach IS
    'COA-21 : par jour et par moment, le nombre d''appels au modèle, d''échecs,
     de tours et de tokens. Le suivi du coût, sans plafond.';
