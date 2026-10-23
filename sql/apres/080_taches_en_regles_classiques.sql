-- =============================================================================
-- 080 : les tâches du foyer repassent en règles classiques           (HDF-4)
--
-- Le HAL du foyer s'occupe maintenant de ce qui est particulier à une tâche :
-- on le lui dit, il le garde en mémoire et le fait respecter. Les règles
-- spéciales posées à la main avant lui quittent donc les tâches du foyer :
--
--   « ensuite »       la tâche qui suivait prend le rythme de celle d'avant
--   « même jour »     le lien part
--   « vaut aussi »    le lien part
--   avant de partir   la case se décoche
--   au retour         le délai s'efface
--
-- Chacune devient une ligne de la mémoire globale du foyer, écrite d'après la
-- règle telle qu'elle est en base au moment du passage : rien ne se perd, HAL
-- le lit à chaque appel. Une tâche reste une tâche classique : son rythme, sa
-- durée, ses heures, pour qui.
--
-- Sur une base sans foyer, celle des tests, rien ne se passe : les liens posés
-- par les migrations restent, et les tests qui les vérifient aussi.
-- =============================================================================

DO $$
DECLARE
    v_foyer   INTEGER;
    v_admin   INTEGER;
    v_lignes  TEXT[] := '{}';
    v_liste   TEXT;
    v_avant   TEXT;
    r         RECORD;
BEGIN
    SELECT id_foyer, id_administrateur INTO v_foyer, v_admin
      FROM foyer WHERE ferme_le IS NULL ORDER BY id_foyer LIMIT 1;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- 1. Une tâche qui ne vivait que d'un « ensuite » prend le rythme de celle
    --    qui la faisait naître. Deux passes : le pliage suit l'étendage, qui
    --    suit la lessive.
    FOR i IN 1..2 LOOP
        UPDATE tache s
           SET recurrente = TRUE,
               periodicite_min_jours = d.pmin,
               periodicite_max_jours = d.pmax
          FROM (SELECT DISTINCT ON (e.id_tache_suivante)
                       e.id_tache_suivante, t.periodicite_min_jours AS pmin,
                       t.periodicite_max_jours AS pmax
                  FROM enchainement e
                  JOIN tache t ON t.id_tache = e.id_tache_source
                 WHERE t.active AND t.recurrente
                 ORDER BY e.id_tache_suivante, t.periodicite_min_jours) d
         WHERE s.id_tache = d.id_tache_suivante AND s.active AND NOT s.recurrente
           AND s.categorie <> 'sport';
    END LOOP;

    -- 2. « Ensuite ». Un lien qu'on ne peut pas retirer sans faire disparaître
    --    sa tâche (elle n'a trouvé aucun rythme) reste en place.
    FOR r IN SELECT e.id_enchainement, s.libelle AS source, n.libelle AS suivante,
                    s.active AND n.active AS actif, e.delai_min_heures AS dmin,
                    e.delai_max_heures AS dmax
               FROM enchainement e
               JOIN tache s ON s.id_tache = e.id_tache_source
               JOIN tache n ON n.id_tache = e.id_tache_suivante
              WHERE s.categorie <> 'sport' AND n.categorie <> 'sport'
              ORDER BY e.id_enchainement LOOP
        BEGIN
            PERFORM delier_taches('ensuite', r.id_enchainement);
            IF r.actif THEN
                v_lignes := v_lignes || format('Après « %s », « %s » se fait %s.', r.source, r.suivante,
                    CASE WHEN r.dmin = 0 THEN format('dans les %s heures', r.dmax)
                         ELSE format('entre %s et %s heures plus tard', r.dmin, r.dmax) END);
            END IF;
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;
    END LOOP;

    -- 3. « Même jour » : la tâche jointe vient avant ou après l'autre.
    FOR r IN SELECT a.id_accompagnement, t.libelle AS tache, j.libelle AS jointe, a.place,
                    a.journee_libre, a.bloc, t.active AND j.active AS actif
               FROM accompagnement a
               JOIN tache t ON t.id_tache = a.id_tache
               JOIN tache j ON j.id_tache = a.id_tache_jointe
              ORDER BY a.id_accompagnement LOOP
        PERFORM delier_taches('meme_jour', r.id_accompagnement);
        IF r.actif THEN
            v_lignes := v_lignes || CASE
                WHEN r.journee_libre THEN format(
                    'Un jour sans cours ni travail, quand « %s » est prévue, « %s » se fait le même jour, juste %s%s.',
                    r.tache, r.jointe, CASE r.place WHEN 'avant' THEN 'avant' ELSE 'après' END,
                    COALESCE(format(' (bloc « %s »)', r.bloc), ''))
                ELSE format(
                    'Quand « %s » est prévue, « %s » se fait le même jour, juste %s, par la même personne.',
                    r.tache, r.jointe, CASE r.place WHEN 'avant' THEN 'avant' ELSE 'après' END)
            END;
        END IF;
    END LOOP;

    -- 4. « Vaut aussi » : faire l'une solde l'autre.
    FOR r IN SELECT m.id_remplacement, f.libelle AS faite, c.libelle AS couverte,
                    f.active AND c.active AS actif
               FROM remplacement m
               JOIN tache f ON f.id_tache = m.id_tache_faite
               JOIN tache c ON c.id_tache = m.id_tache_couverte
              ORDER BY m.id_remplacement LOOP
        PERFORM delier_taches('vaut_aussi', r.id_remplacement);
        IF r.actif THEN
            v_lignes := v_lignes || format(
                'Faire « %s » compte aussi pour « %s » : pas besoin des deux le même jour.',
                r.faite, r.couverte);
        END IF;
    END LOOP;

    -- 5. Avant de partir.
    SELECT string_agg(format('« %s »', libelle), ', ' ORDER BY id_tache) INTO v_liste
      FROM tache WHERE active AND avant_depart AND categorie <> 'sport';
    IF v_liste IS NOT NULL THEN
        v_lignes := v_lignes || format(
            'Avant un départ qui laisse l''appartement vide, prévoir : %s.', v_liste);
    END IF;
    UPDATE tache SET avant_depart = FALSE WHERE avant_depart AND categorie <> 'sport';

    -- 6. Au retour.
    FOR r IN SELECT libelle, au_retour_apres_jours AS jours
               FROM tache
              WHERE active AND au_retour_apres_jours IS NOT NULL AND categorie <> 'sport'
              ORDER BY id_tache LOOP
        v_lignes := v_lignes || format(
            'Au retour, si l''appartement est resté vide plus de %s jours : « %s ».', r.jours, r.libelle);
    END LOOP;
    UPDATE tache SET au_retour_apres_jours = NULL
     WHERE au_retour_apres_jours IS NOT NULL AND categorie <> 'sport';

    -- 7. La mémoire globale du foyer, à la suite de ce qu'elle dit déjà.
    IF cardinality(v_lignes) = 0 THEN
        RETURN;
    END IF;
    SELECT texte INTO v_avant FROM v_memoire_foyer WHERE id_foyer = v_foyer AND niveau = 'globale';
    PERFORM ecrire_memoire_foyer(
        v_foyer, 'globale',
        concat_ws(E'\n\n', NULLIF(btrim(v_avant), ''),
                  'Habitudes des tâches, à faire respecter au planning :' || E'\n'
                  || array_to_string(ARRAY(SELECT '- ' || l FROM unnest(v_lignes) l), E'\n')),
        CASE WHEN v_admin IS NULL THEN 'hal' ELSE 'utilisateur' END, v_admin);
END $$;
