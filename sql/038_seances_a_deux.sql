-- rejouable : ce fichier ne contient que des CREATE ... IF NOT EXISTS, des
--             ALTER ... IF [NOT] EXISTS et des CREATE OR REPLACE.
-- =============================================================================
-- 038 : les séances à deux                                    (SPT-30 à SPT-32)
--
-- Faire du sport à deux se décide autrement que seul. Le système sait déjà qui
-- est libre quand : il peut donc dire « ce créneau vous va à tous les deux »,
-- et le proposer en premier.
--
-- Ce qu'il ne fait pas, et ne doit pas faire : décider pour l'autre. Choisir
-- une séance à deux ne crée pas la séance de l'autre, elle l'invite. L'autre
-- répond, et une seule des deux réponses engage quelqu'un.
--
-- Et une invitation refusée, ou laissée sans réponse, ne défait rien : la
-- séance du premier tient. On peut très bien y aller seul, c'était le créneau
-- qui était commun, pas l'obligation.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Qui d'autre pourrait venir                                        (SPT-30)
--
-- Tous les autres comptes actifs. À deux dans l'appartement cela fait une
-- personne, mais rien dans le modèle n'oblige à rester deux.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION partenaires_sport(p_utilisateur INTEGER)
RETURNS SETOF INTEGER LANGUAGE sql STABLE AS $$
    SELECT u.id_utilisateur
      FROM utilisateur u
     WHERE u.actif
       AND u.id_utilisateur <> p_utilisateur
     ORDER BY u.id_utilisateur;
$$;

COMMENT ON FUNCTION partenaires_sport IS
    'Les autres comptes actifs, ceux à qui une séance peut être proposée à
     deux (SPT-30).';


-- Libre au même moment, au sens strict : ni cours, ni service, ni séance déjà
-- choisie ce jour-là. Le lieu compte, puisqu'il porte la durée et le trajet.
CREATE OR REPLACE FUNCTION seance_possible_a_deux(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM partenaires_sport(p_utilisateur) p
         WHERE obstacle_seance(p, p_lieu, p_debut, NULL, TRUE) IS NULL);
$$;

COMMENT ON FUNCTION seance_possible_a_deux IS
    'Vrai si au moins une autre personne tient ce créneau, au même endroit et
     à la même heure (SPT-30).';


-- -----------------------------------------------------------------------------
-- 2. L'invitation                                              (SPT-31, SPT-32)
--
-- Une ligne par personne invitée sur une séance. Elle meurt avec la séance :
-- supprimer sa séance retire l'invitation, elle n'a plus d'objet. La séance
-- créée en réponse, elle, ne meurt pas : elle appartient à celui qui a
-- accepté, et il peut la garder même si l'autre annule (SPT-32).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS invitation_sport (
    id_invitation   SERIAL      PRIMARY KEY,
    id_occurrence   INTEGER     NOT NULL REFERENCES occurrence (id_occurrence)
                                ON DELETE CASCADE,
    id_invite       INTEGER     NOT NULL REFERENCES utilisateur (id_utilisateur)
                                ON DELETE CASCADE,
    statut          VARCHAR(10) NOT NULL DEFAULT 'attente'
                                CHECK (statut IN ('attente', 'acceptee', 'refusee')),
    id_occurrence_reponse INTEGER REFERENCES occurrence (id_occurrence)
                                ON DELETE SET NULL,
    date_creation   TIMESTAMPTZ NOT NULL DEFAULT now(),
    date_reponse    TIMESTAMPTZ,
    UNIQUE (id_occurrence, id_invite)
);

COMMENT ON TABLE invitation_sport IS
    'Une séance proposée à quelqu''un d''autre. Tant qu''elle est en attente,
     elle n''engage personne (SPT-31).';


-- La notification porte l'invitation : c'est elle qui donne ses deux boutons.
ALTER TABLE notification ADD COLUMN IF NOT EXISTS id_invitation INTEGER
    REFERENCES invitation_sport (id_invitation) ON DELETE CASCADE;

COMMENT ON COLUMN notification.id_invitation IS
    'Renseignée sur une invitation à une séance à deux : le bot en tire les
     boutons « je viens » et « pas cette fois » (SPT-31).';


-- -----------------------------------------------------------------------------
-- 3. Inviter                                                           (SPT-31)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inviter_a_la_seance(p_occurrence INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o          RECORD;
    v_lieu     TEXT;
    v_qui      TEXT;
    p          INTEGER;
    v_invitation INTEGER;
    v_n        INTEGER := 0;
BEGIN
    SELECT oc.id_occurrence, oc.id_utilisateur, oc.id_lieu, oc.debut_seance
      INTO o
      FROM occurrence oc
      JOIN tache t ON t.id_tache = oc.id_tache
     WHERE oc.id_occurrence = p_occurrence
       AND t.code = 'SPORT'
       AND oc.origine <> 'quota'
       AND oc.statut IN ('planifiee', 'notifiee');
    IF NOT FOUND OR o.debut_seance IS NULL THEN
        RETURN 0;
    END IF;

    SELECT libelle INTO v_lieu FROM lieu_sport WHERE id_lieu = o.id_lieu;
    SELECT nom INTO v_qui FROM utilisateur WHERE id_utilisateur = o.id_utilisateur;

    FOR p IN SELECT s FROM partenaires_sport(o.id_utilisateur) s LOOP
        -- On n'invite que qui peut venir : une invitation à un créneau de
        -- cours se referme sur un refus qui n'apprend rien à personne.
        CONTINUE WHEN obstacle_seance(p, o.id_lieu, o.debut_seance, NULL, TRUE) IS NOT NULL;

        INSERT INTO invitation_sport (id_occurrence, id_invite)
        VALUES (p_occurrence, p)
        ON CONFLICT (id_occurrence, id_invite) DO NOTHING
        RETURNING id_invitation INTO v_invitation;

        CONTINUE WHEN v_invitation IS NULL;   -- déjà invitée

        INSERT INTO notification (id_utilisateur, type, contenu, id_invitation)
        VALUES (p, 'sport',
                format('%s fait %s le %s. Tu viens ?',
                       v_qui, lower(v_lieu),
                       to_char(o.debut_seance AT TIME ZONE 'Europe/Paris',
                               'DD/MM à HH24hMI')),
                v_invitation);
        v_n := v_n + 1;
    END LOOP;

    RETURN v_n;
END $$;

COMMENT ON FUNCTION inviter_a_la_seance IS
    'Invite les autres comptes libres sur ce créneau, et leur envoie la
     question. N''engage personne (SPT-31).';


-- -----------------------------------------------------------------------------
-- 4. Répondre                                                  (SPT-31, SPT-32)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION repondre_invitation(p_invitation  INTEGER,
                                               p_utilisateur INTEGER,
                                               p_vient       BOOLEAN)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    i            RECORD;
    v_occurrence INTEGER;
BEGIN
    SELECT inv.*, o.id_lieu, o.debut_seance
      INTO i
      FROM invitation_sport inv
      JOIN occurrence o ON o.id_occurrence = inv.id_occurrence
     WHERE inv.id_invitation = p_invitation
       AND inv.id_invite = p_utilisateur
     FOR UPDATE OF inv;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation introuvable' USING ERRCODE = 'no_data_found';
    END IF;

    IF i.statut <> 'attente' THEN
        RAISE EXCEPTION 'Tu as déjà répondu à cette invitation'
              USING ERRCODE = 'check_violation';
    END IF;

    IF NOT p_vient THEN
        UPDATE invitation_sport
           SET statut = 'refusee', date_reponse = now()
         WHERE id_invitation = p_invitation;
        RETURN NULL;
    END IF;

    -- Accepter, c'est choisir cette séance pour soi : elle passe par les mêmes
    -- règles que n'importe quel choix, et peut donc être refusée si l'emploi
    -- du temps a changé depuis l'invitation.
    v_occurrence := choisir_seance_sport(p_utilisateur, i.id_lieu, i.debut_seance,
                                         NULL, 'a_deux');

    UPDATE invitation_sport
       SET statut = 'acceptee', date_reponse = now(),
           id_occurrence_reponse = v_occurrence
     WHERE id_invitation = p_invitation;

    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION repondre_invitation IS
    'Accepter crée sa propre séance au même endroit et à la même heure ;
     refuser ne touche à rien. Dans les deux cas la séance de celui qui a
     invité reste (SPT-31, SPT-32).';


-- « a_deux » rejoint les origines de choix : on veut pouvoir distinguer, dans
-- les habitudes, une séance décidée seul d'une séance acceptée.
ALTER TABLE choix_sport DROP CONSTRAINT IF EXISTS choix_sport_origine_check;
ALTER TABLE choix_sport ADD CONSTRAINT choix_sport_origine_check
    CHECK (origine IN ('proposition', 'habitude', 'modifiee', 'manuelle',
                       'reprise', 'a_deux'));


-- -----------------------------------------------------------------------------
-- 5. Ce que l'autre en sait                                            (SPT-32)
--
-- Une séance sait si quelqu'un a dit qu'il venait : l'écran le montre, et
-- c'est tout ce dont il a besoin.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION compagnons_de_seance(p_occurrence INTEGER)
RETURNS TABLE (nom TEXT, statut TEXT)
LANGUAGE sql STABLE AS $$
    SELECT u.nom::TEXT, inv.statut::TEXT
      FROM invitation_sport inv
      JOIN utilisateur u ON u.id_utilisateur = inv.id_invite
     WHERE inv.id_occurrence = p_occurrence
     ORDER BY u.nom;
$$;

COMMENT ON FUNCTION compagnons_de_seance IS
    'Qui a été invité sur cette séance, et ce qu''il a répondu (SPT-32).';
