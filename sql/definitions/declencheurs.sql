CREATE OR REPLACE TRIGGER occurrence_heriter_tache
    BEFORE INSERT ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_occurrence_heriter_tache();


CREATE OR REPLACE TRIGGER occurrence_transition
    BEFORE UPDATE ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_occurrence_transition();


CREATE OR REPLACE TRIGGER occurrence_close
    BEFORE UPDATE OF statut, date_faite, fenetre, creneau ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_occurrence_close();


CREATE OR REPLACE TRIGGER occurrence_machine_unique
    BEFORE INSERT OR UPDATE OF creneau, statut ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_machine_unique();


CREATE OR REPLACE TRIGGER occurrence_apres_validation
    AFTER UPDATE OF statut ON occurrence
    FOR EACH ROW
    WHEN (NEW.statut = 'faite' AND OLD.statut IS DISTINCT FROM 'faite')
    EXECUTE FUNCTION trg_occurrence_apres_validation();


CREATE OR REPLACE TRIGGER occupation_reverifier_propositions
    AFTER INSERT OR UPDATE OR DELETE ON occupation
    FOR EACH STATEMENT EXECUTE FUNCTION trg_occupation_reverifier();


-- -----------------------------------------------------------------------------
-- Le journal                                                     (JRN-1 à JRN-6)
--
-- Chaque table suivie donne ses colonnes : ce sont elles qui font un événement.
-- Le premier argument dit qui peut le lire, « foyer » ou « technique ».
--
-- L'URL d'une source n'est pas suivie : celle d'un calendrier privé contient
-- son jeton d'accès, et le journal n'a pas à en garder une copie.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER journal_occurrence
    AFTER INSERT OR UPDATE OR DELETE ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_utilisateur', 'creneau', 'statut', 'motif', 'fenetre', 'epinglee');


CREATE OR REPLACE TRIGGER journal_absence
    AFTER INSERT OR UPDATE OR DELETE ON absence
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_utilisateur', 'periode', 'lieu', 'origine');


CREATE OR REPLACE TRIGGER journal_allegement
    AFTER INSERT OR UPDATE OR DELETE ON allegement
    FOR EACH ROW EXECUTE FUNCTION trg_journal('foyer', 'id_utilisateur', 'periode');


CREATE OR REPLACE TRIGGER journal_proposition
    AFTER INSERT OR UPDATE OR DELETE ON proposition
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_utilisateur', 'periode', 'lieu', 'statut', 'annoncee_le');


CREATE OR REPLACE TRIGGER journal_trajet
    AFTER INSERT OR UPDATE OR DELETE ON trajet
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_utilisateur', 'sens', 'periode', 'statut');


CREATE OR REPLACE TRIGGER journal_courriel
    AFTER INSERT OR UPDATE OR DELETE ON courriel
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_utilisateur', 'statut', 'motif', 'reference', 'id_absence');


CREATE OR REPLACE TRIGGER journal_occupation
    AFTER INSERT OR UPDATE OR DELETE ON occupation
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_utilisateur', 'type', 'libelle', 'periode', 'lieu');


CREATE OR REPLACE TRIGGER journal_conflit
    AFTER INSERT OR UPDATE OR DELETE ON conflit
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'statut', 'choix', 'periode', 'motif_caducite');


CREATE OR REPLACE TRIGGER journal_notification
    AFTER INSERT OR UPDATE OR DELETE ON notification
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_utilisateur', 'type', 'statut');


CREATE OR REPLACE TRIGGER journal_tache
    AFTER INSERT OR UPDATE OR DELETE ON tache
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'libelle', 'active', 'duree_minutes', 'periodicite_min_jours',
        'periodicite_max_jours', 'heure_min', 'heure_max', 'id_utilisateur_defaut',
        'priorite', 'avant_depart', 'id_type_tache', 'si_pas_faite',
        'rythme_nombre', 'rythme_periode', 'rythme_moment', 'penibilite');


-- CND-11 : une règle se pose, se suspend et se retire dans l'appli, par l'un
-- ou l'autre. Elle se lit à deux, comme la tâche.
CREATE OR REPLACE TRIGGER journal_regle_tache
    AFTER INSERT OR UPDATE OR DELETE ON regle_tache
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_tache', 'traduction', 'etat', 'validite');


-- CND-3 à CND-6 : une brique mal formée ne s'écrit pas.
CREATE OR REPLACE TRIGGER brique_regle_verifier
    BEFORE INSERT OR UPDATE ON brique_regle
    FOR EACH ROW EXECUTE FUNCTION trg_brique_regle_verifier();


-- CND-4 : une tâche à rythme garde une périodicité équivalente.
CREATE OR REPLACE TRIGGER tache_rythme
    BEFORE INSERT OR UPDATE OF rythme_nombre, rythme_periode, periodicite_min_jours,
                               periodicite_max_jours ON tache
    FOR EACH ROW EXECUTE FUNCTION trg_tache_rythme();


-- TAC-25 à TAC-27 : les types et les liens se règlent dans l'appli, par l'un
-- ou l'autre. Ils se lisent donc à deux, comme les tâches.
CREATE OR REPLACE TRIGGER journal_type_tache
    AFTER INSERT OR UPDATE OR DELETE ON type_tache
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'libelle', 'couleur', 'icone', 'duree_minutes', 'priorite', 'penibilite');


CREATE OR REPLACE TRIGGER journal_enchainement
    AFTER INSERT OR UPDATE OR DELETE ON enchainement
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_tache_source', 'id_tache_suivante', 'delai_min_heures', 'delai_max_heures');


CREATE OR REPLACE TRIGGER journal_accompagnement
    AFTER INSERT OR UPDATE OR DELETE ON accompagnement
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_tache', 'id_tache_jointe', 'place', 'mention');


CREATE OR REPLACE TRIGGER journal_remplacement
    AFTER INSERT OR UPDATE OR DELETE ON remplacement
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_tache_faite', 'id_tache_couverte');


CREATE OR REPLACE TRIGGER journal_utilisateur
    AFTER UPDATE ON utilisateur
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'actif', 'lieu_famille', 'gare_famille',
        'coach_actif', 'id_foyer');


-- FOY-2, FOY-6 : qui administre le foyer, et ce qu'il permet aux autres.
CREATE OR REPLACE TRIGGER journal_foyer
    AFTER INSERT OR UPDATE ON foyer
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'nom', 'id_administrateur', 'ajout_taches', 'modif_taches',
        'ferme_le');


CREATE OR REPLACE TRIGGER journal_source
    AFTER INSERT OR UPDATE OR DELETE ON source
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'technique', 'libelle', 'etat', 'active', 'frequence_heures',
        'id_utilisateur');


-- -----------------------------------------------------------------------------
-- Le module coach
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER seance_etat
    AFTER INSERT OR UPDATE OF etat, discipline, libre ON seance
    FOR EACH ROW EXECUTE FUNCTION trg_seance_etat();


CREATE OR REPLACE TRIGGER seance_exercice_actif
    BEFORE INSERT OR UPDATE OF id_exercice ON seance_exercice
    FOR EACH ROW EXECUTE FUNCTION trg_seance_exercice();


CREATE OR REPLACE TRIGGER seance_exercice_groupes
    AFTER INSERT OR UPDATE OF id_exercice OR DELETE ON seance_exercice
    FOR EACH ROW EXECUTE FUNCTION trg_seance_exercice();


CREATE OR REPLACE TRIGGER serie_saisie_controle
    BEFORE INSERT OR UPDATE OR DELETE ON serie_saisie
    FOR EACH ROW EXECUTE FUNCTION trg_serie_saisie();


CREATE OR REPLACE TRIGGER exercice_conserve
    BEFORE DELETE ON exercice
    FOR EACH ROW EXECUTE FUNCTION trg_exercice_conserve();


CREATE OR REPLACE TRIGGER objectif_clos
    BEFORE UPDATE OF statut ON objectif
    FOR EACH ROW EXECUTE FUNCTION trg_objectif_clos();


CREATE OR REPLACE TRIGGER absence_seances
    AFTER INSERT OR UPDATE OF periode ON absence
    FOR EACH ROW EXECUTE FUNCTION trg_absence_seances();


-- JRN-10 : les objectifs et le plan se lisent à deux, comme le reste du
-- journal. Le profil, le dépistage, la santé, les mesures, les bilans, les
-- limitations, la pause, le carnet, les échanges et les appels ne sont pas
-- suivis ici : ce qui est privé ne doit pas pouvoir se lire depuis /pourquoi.
CREATE OR REPLACE TRIGGER journal_objectif
    AFTER INSERT OR UPDATE OR DELETE ON objectif
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_utilisateur', 'libelle', 'statut', 'principal', 'echeance',
        'cible_valeur');


CREATE OR REPLACE TRIGGER journal_plan
    AFTER INSERT OR UPDATE OR DELETE ON plan
    FOR EACH ROW EXECUTE FUNCTION trg_journal(
        'foyer', 'id_utilisateur', 'periode', 'statut');


-- MEM-8 : l'importance d'un échange se calcule à son écriture.
CREATE OR REPLACE TRIGGER echange_importance
    BEFORE INSERT ON echange
    FOR EACH ROW EXECUTE FUNCTION trg_echange_importance();


CREATE OR REPLACE TRIGGER echange_importance_reportee
    AFTER INSERT ON echange
    FOR EACH ROW EXECUTE FUNCTION trg_echange_importance();
