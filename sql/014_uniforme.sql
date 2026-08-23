-- rejouable : ADD COLUMN IF NOT EXISTS et CREATE OR REPLACE.
-- =============================================================================
-- 014 : consommation de l'uniforme                            (UNI-5 à UNI-7)
--
-- La fonction de consommation existait mais n'était appelée nulle part : le
-- stock restait plein et la projection de lessive ne déclenchait jamais rien.
--
-- Elle salissait de plus le pantalon un jour de calendrier sur deux, alors que
-- la règle porte sur les journées travaillées. D'où un compteur.
-- =============================================================================

ALTER TABLE article_travail
    ADD COLUMN IF NOT EXISTS journees_portees SMALLINT NOT NULL DEFAULT 0
        CHECK (journees_portees >= 0);

-- UNI-6 : sans cette date, relancer la consommation deux fois dans la journée
-- salirait deux t-shirts pour un seul service.
ALTER TABLE article_travail
    ADD COLUMN IF NOT EXISTS dernier_jour_compte DATE;

COMMENT ON COLUMN article_travail.journees_portees IS
    'Journées de travail depuis la dernière mise au sale. Remis à zéro quand
     l''article part au linge (UNI-5).';

COMMENT ON COLUMN article_travail.dernier_jour_compte IS
    'Dernière journée déjà comptée. Rend la consommation rejouable : le Mac
     dort, l''ordonnanceur saute des jours, et il faut pouvoir rattraper sans
     compter deux fois (UNI-6).';


-- -----------------------------------------------------------------------------
-- Consommer une journée de travail                                 (UNI-5, UNI-6)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION consommer_uniforme(p_jour DATE) RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    a       RECORD;
    v_sales INTEGER := 0;
BEGIN
    -- Pas de service ce jour-là : l'uniforme n'a pas été porté.
    IF NOT EXISTS (
        SELECT 1 FROM occupation
         WHERE type = 'travail' AND jour_de(lower(periode)) = p_jour
    ) THEN
        RETURN 0;
    END IF;

    FOR a IN SELECT * FROM article_travail ORDER BY id_article LOOP
        -- UNI-6 : journée déjà comptée, on passe. C'est ce qui permet de
        -- rattraper plusieurs jours d'un coup sans rien salir en double.
        CONTINUE WHEN a.dernier_jour_compte IS NOT NULL
                  AND a.dernier_jour_compte >= p_jour;

        IF a.journees_portees + 1 >= a.jours_par_unite THEN
            INSERT INTO mouvement_stock (id_article, type, quantite)
            VALUES (a.id_article, 'salissure', 1);

            UPDATE article_travail
               SET journees_portees = 0, dernier_jour_compte = p_jour
             WHERE id_article = a.id_article;

            v_sales := v_sales + 1;
        ELSE
            UPDATE article_travail
               SET journees_portees = a.journees_portees + 1,
                   dernier_jour_compte = p_jour
             WHERE id_article = a.id_article;
        END IF;
    END LOOP;

    RETURN v_sales;
END $$;


-- -----------------------------------------------------------------------------
-- Rattraper les journées manquées                                        (UNI-7)
--
-- L'ordonnanceur ne tourne que machine allumée : ne traiter qu'hier ferait
-- perdre une semaine de services au premier week-end. On repart donc du
-- dernier jour compté.
--
-- Aujourd'hui est exclu : un service du soir n'est pas fini le matin.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rattraper_uniforme(p_max_jours INTEGER DEFAULT 60)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_depuis DATE;
    v_jour   DATE;
    v_sales  INTEGER := 0;
BEGIN
    SELECT COALESCE(max(dernier_jour_compte), jour_de(now()) - p_max_jours)
      INTO v_depuis
      FROM article_travail;

    v_jour := GREATEST(v_depuis + 1, jour_de(now()) - p_max_jours);

    WHILE v_jour < jour_de(now()) LOOP
        v_sales := v_sales + consommer_uniforme(v_jour);
        v_jour := v_jour + 1;
    END LOOP;

    RETURN v_sales;
END $$;

COMMENT ON FUNCTION rattraper_uniforme IS
    'Consomme toutes les journées travaillées non encore comptées, jusqu''à
     hier inclus. Idempotente (UNI-7).';


-- Un lavage remet le compteur à zéro : c'est le sens même de « propre ».
CREATE OR REPLACE FUNCTION trg_mouvement_compteur() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.type = 'retour_propre' THEN
        UPDATE article_travail SET journees_portees = 0
         WHERE id_article = NEW.id_article;
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER mouvement_compteur
    AFTER INSERT ON mouvement_stock
    FOR EACH ROW EXECUTE FUNCTION trg_mouvement_compteur();
