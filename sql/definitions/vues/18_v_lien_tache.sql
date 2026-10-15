-- -----------------------------------------------------------------------------
-- Les liens entre tâches, d'une seule liste                    (TAC-27, TAC-28)
--
-- Trois tables portent trois sortes de liens. L'appli les montre ensemble dans
-- le détail d'une tâche, des deux côtés : « Vider le lave-vaisselle, entre 8 et
-- 20 h après » depuis le lancement, « Naît après Lancer le lave-vaisselle »
-- depuis le vidage. Les deux phrases se font ici, une fois pour tous les
-- clients (WID-8).
-- -----------------------------------------------------------------------------
CREATE VIEW v_lien_tache AS
WITH liens AS (
    SELECT 'ensuite'::TEXT AS sorte, e.id_enchainement AS id_lien,
           e.id_tache_source AS id_de, e.id_tache_suivante AS id_vers,
           e.delai_min_heures, e.delai_max_heures,
           NULL::TEXT AS place, NULL::TEXT AS mention, FALSE AS journee_libre, NULL::TEXT AS bloc
      FROM enchainement e
    UNION ALL
    SELECT 'meme_jour', a.id_accompagnement, a.id_tache, a.id_tache_jointe,
           NULL, NULL, a.place, a.mention, a.journee_libre, a.bloc
      FROM accompagnement a
    UNION ALL
    SELECT 'vaut_aussi', r.id_remplacement, r.id_tache_faite, r.id_tache_couverte,
           NULL, NULL, NULL, NULL, FALSE, NULL
      FROM remplacement r
)
SELECT
    l.sorte,
    l.id_lien,
    l.id_de,
    de.libelle   AS libelle_de,
    l.id_vers,
    vers.libelle AS libelle_vers,
    l.delai_min_heures,
    l.delai_max_heures,
    l.place,
    l.mention,
    l.journee_libre,
    l.bloc,
    de.active AND vers.active AS actif,

    -- Le délai en mots : « dans les 12 h », « entre 8 et 20 h après ».
    CASE WHEN l.sorte <> 'ensuite' THEN NULL
         WHEN l.delai_min_heures = 0 THEN format('dans les %s h', l.delai_max_heures)
         ELSE format('entre %s et %s h après', l.delai_min_heures, l.delai_max_heures)
    END AS delai,

    -- Lu depuis la tâche de départ.
    CASE l.sorte
        WHEN 'ensuite' THEN
            format('%s, %s', vers.libelle,
                   CASE WHEN l.delai_min_heures = 0 THEN format('dans les %s h', l.delai_max_heures)
                        ELSE format('entre %s et %s h après', l.delai_min_heures, l.delai_max_heures) END)
        WHEN 'meme_jour' THEN
            format('%s, le même jour, %s', vers.libelle,
                   CASE l.place WHEN 'avant' THEN 'avant' ELSE 'après' END)
            || CASE WHEN l.journee_libre THEN format(' (les jours sans cours, bloc « %s »)', l.bloc) ELSE '' END
        ELSE vers.libelle
    END AS phrase_depuis,

    -- Lu depuis la tâche d'arrivée.
    CASE l.sorte
        WHEN 'ensuite' THEN
            format('Naît après « %s », %s', de.libelle,
                   CASE WHEN l.delai_min_heures = 0 THEN format('dans les %s h', l.delai_max_heures)
                        ELSE format('entre %s et %s h après', l.delai_min_heures, l.delai_max_heures) END)
        WHEN 'meme_jour' THEN
            format('Vient le jour de « %s », %s elle', de.libelle,
                   CASE l.place WHEN 'avant' THEN 'avant' ELSE 'après' END)
        ELSE format('Couverte par « %s »', de.libelle)
    END AS phrase_vers
FROM liens l
JOIN tache de   ON de.id_tache = l.id_de
JOIN tache vers ON vers.id_tache = l.id_vers;

COMMENT ON VIEW v_lien_tache IS
    'TAC-27 : les enchaînements, accompagnements et remplacements d''une seule
     liste, avec la phrase qui les dit depuis chacune des deux tâches.';
