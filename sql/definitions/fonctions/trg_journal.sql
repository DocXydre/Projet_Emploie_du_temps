-- -----------------------------------------------------------------------------
-- Noter ce qui change                                            (JRN-1 à JRN-5)
--
-- Un seul déclencheur pour toutes les tables suivies. Ses arguments : la
-- visibilité (« foyer » ou « technique »), puis les colonnes à suivre. Une
-- retouche qui ne change aucune de ces colonnes ne laisse rien : la collecte
-- réécrit quatre-vingts cours identiques toutes les heures, et ce n'est pas un
-- événement.
--
-- JRN-2 : une ligne par objet et par opération. Le placement défait tout ce qui
-- n'est pas gelé avant de le reposer. Noter chaque geste donnerait quarante
-- lignes pour dire que rien n'a bougé. On garde donc l'état d'avant
-- l'opération et le dernier état connu : si la ligne revient à son point de
-- départ, l'événement disparaît.
--
-- JRN-5 : le journal ne fait jamais échouer ce qu'il observe. Une erreur ici
-- est rendue en avertissement, et l'opération continue.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_journal() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_colonnes  TEXT[] := '{}';
    v_ancienne  JSONB;
    v_nouvelle  JSONB;
    v_avant     JSONB;
    v_apres     JSONB;
    v_id        BIGINT;
    v_operation TEXT;
    v_existant  RECORD;
BEGIN
    FOR i IN 1 .. TG_NARGS - 1 LOOP
        v_colonnes := v_colonnes || TG_ARGV[i];
    END LOOP;

    IF TG_OP <> 'INSERT' THEN v_ancienne := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN v_nouvelle := to_jsonb(NEW); END IF;

    SELECT jsonb_object_agg(cle, valeur) INTO v_avant
      FROM jsonb_each(v_ancienne) AS c(cle, valeur) WHERE cle = ANY (v_colonnes);
    SELECT jsonb_object_agg(cle, valeur) INTO v_apres
      FROM jsonb_each(v_nouvelle) AS c(cle, valeur) WHERE cle = ANY (v_colonnes);

    IF v_avant IS NOT DISTINCT FROM v_apres THEN
        RETURN NULL;
    END IF;

    -- Chercher un train en propose une vingtaine. Seul celui qu'on retient, ou
    -- qu'on abandonne après l'avoir retenu, est un événement.
    IF TG_TABLE_NAME = 'trajet'
       AND COALESCE(v_avant ->> 'statut', '') <> 'retenue'
       AND COALESCE(v_apres ->> 'statut', '') <> 'retenue' THEN
        RETURN NULL;
    END IF;

    v_id := (COALESCE(v_nouvelle, v_ancienne) ->> ('id_' || TG_TABLE_NAME))::BIGINT;
    v_operation := COALESCE(NULLIF(current_setting('planif.operation', TRUE), ''),
                            'tx' || txid_current());

    SELECT e.id_evenement, e.avant INTO v_existant
      FROM evenement e
     WHERE e.operation = v_operation
       AND e.objet = TG_TABLE_NAME
       AND e.id_objet = v_id
     ORDER BY e.id_evenement
     LIMIT 1;

    IF FOUND THEN
        IF v_existant.avant IS NOT DISTINCT FROM v_apres THEN
            -- Retour au point de départ : il ne s'est rien passé.
            DELETE FROM evenement WHERE id_evenement = v_existant.id_evenement;
        ELSE
            UPDATE evenement
               SET apres = v_apres, quand = clock_timestamp()
             WHERE id_evenement = v_existant.id_evenement;
        END IF;
    ELSE
        INSERT INTO evenement (operation, acteur, origine, objet, id_objet,
                               libelle, avant, apres, technique)
        VALUES (v_operation,
                COALESCE(NULLIF(current_setting('planif.acteur', TRUE), ''), 'direct'),
                NULLIF(current_setting('planif.origine', TRUE), ''),
                TG_TABLE_NAME, v_id,
                libelle_journal(TG_TABLE_NAME, COALESCE(v_nouvelle, v_ancienne)),
                v_avant, v_apres,
                TG_ARGV[0] = 'technique');
    END IF;

    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'journal (% sur %) : %', TG_OP, TG_TABLE_NAME, SQLERRM;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION trg_journal() IS
    'JRN-1 à JRN-5 : note l''état avant et après une opération, une ligne par
     objet. Arguments : « foyer » ou « technique », puis les colonnes suivies.';
