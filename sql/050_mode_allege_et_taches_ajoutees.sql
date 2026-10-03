-- =============================================================================
-- 050 : le mode allégé, et les tâches qu'on ajoute soi-même    (PLA-16, TAC-20)
--
-- Rejouable.
--
-- Deux choses qui demandaient jusqu'ici de passer par la base.
--
-- Le mode allégé : une semaine d'examens, un coup de fatigue. Celui qui
-- l'active fait la moitié de sa part pendant la durée qu'il donne, et l'autre
-- prend ce qu'il ne fait pas. Activé par les deux en même temps, il s'annule :
-- on ne vit pas dans la crasse.
--
-- Les tâches ajoutées : un cycle long (« nettoyer le four, tous les trois
-- mois ») ou une chose à faire une fois avant une date (« rendre le colis avant
-- vendredi »). Elles se créent depuis Telegram et se placent comme les autres.
--
-- Aucune fonction ici : elles sont dans sql/definitions/.
-- =============================================================================

CREATE TABLE IF NOT EXISTS allegement (
    id_allegement  SERIAL      PRIMARY KEY,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur(id_utilisateur),
    periode        TSTZRANGE   NOT NULL,
    date_creation  TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Une durée est donnée au lancement : un mode qu'on oublie allumé finit par
    -- devenir la répartition normale, sans que personne l'ait décidé.
    CONSTRAINT allegement_periode_bornee
        CHECK (NOT isempty(periode)
               AND lower(periode) IS NOT NULL
               AND upper(periode) IS NOT NULL),
    CONSTRAINT allegement_sans_chevauchement
        EXCLUDE USING gist (id_utilisateur WITH =, periode WITH &&)
);

COMMENT ON TABLE allegement IS
    'PLA-16 : les périodes où quelqu''un a demandé à en faire moins. Pendant
     ce temps il fait un quart des tâches partagées, et l''autre trois quarts.';


-- Qui a ajouté la tâche. Vide pour les tâches de référence : c'est ce qui
-- distingue celles qu'on peut arrêter depuis Telegram.
ALTER TABLE tache ADD COLUMN IF NOT EXISTS ajoutee_par INTEGER
    REFERENCES utilisateur(id_utilisateur);

COMMENT ON COLUMN tache.ajoutee_par IS
    'TAC-20 : le compte qui a créé la tâche depuis le bot. Vide pour les tâches
     de référence.';
