CREATE OR REPLACE FUNCTION trg_echange_importance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND TG_WHEN = 'BEFORE' THEN
        IF NEW.operation IS NOT NULL THEN
            NEW.importance := GREATEST(NEW.importance,
                                       importance_operation(NEW.operation, NEW.moment));
        ELSIF NEW.moment = 'signalement' THEN
            NEW.importance := GREATEST(NEW.importance, 2);
        END IF;
        RETURN NEW;
    END IF;
    -- Après : le message de l'utilisateur prend l'importance de la réponse.
    IF NEW.auteur IN ('coach', 'systeme') AND NEW.id_appel IS NOT NULL THEN
        UPDATE echange e SET importance = NEW.importance
         WHERE e.id_appel = NEW.id_appel AND e.auteur = 'utilisateur'
           AND e.importance < NEW.importance;
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION trg_echange_importance() IS
    'MEM-8 : calcule l''importance d''un échange à son écriture, et la reporte
     sur le message de l''utilisateur auquel il répond.';
