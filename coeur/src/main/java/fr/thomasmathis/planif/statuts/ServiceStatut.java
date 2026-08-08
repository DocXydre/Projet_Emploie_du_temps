package fr.thomasmathis.planif.statuts;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.journal.ServiceJournal;
import fr.thomasmathis.planif.taches.CategorieTache;

/**
 * Declaration et fin des statuts globaux.
 *
 * <p>Ce service dit <b>quel effet</b> s'applique a chaque categorie, en lisant
 * la table {@code regle_statut}. L'application concrete de ces effets sur les
 * occurrences (gel, report, reassignation) appartient au moteur, au lot 3.</p>
 */
@Service
public class ServiceStatut {

    private final DepotStatutUtilisateur depot;
    private final DepotRegleStatut depotRegles;
    private final ServiceJournal journal;
    private final Clock horloge;

    public ServiceStatut(DepotStatutUtilisateur depot, DepotRegleStatut depotRegles,
                         ServiceJournal journal, Clock horloge) {
        this.depot = depot;
        this.depotRegles = depotRegles;
        this.journal = journal;
        this.horloge = horloge;
    }

    /** Statut ouvert d'un utilisateur. Absence de statut declare vaut ACTIF. */
    @Transactional(readOnly = true)
    public Optional<StatutUtilisateur> courant(Long utilisateurId) {
        return depot.findByUtilisateurIdAndFinReelleIsNull(utilisateurId);
    }

    @Transactional(readOnly = true)
    public TypeStatut typeCourant(Long utilisateurId) {
        return courant(utilisateurId).map(StatutUtilisateur::getType).orElse(TypeStatut.ACTIF);
    }

    @Transactional(readOnly = true)
    public List<StatutUtilisateur> historique(Long utilisateurId) {
        return depot.findByUtilisateurIdOrderByDebutDesc(utilisateurId);
    }

    /**
     * Declare un statut. Le statut ouvert precedent est ferme automatiquement :
     * un seul statut ouvert par utilisateur, c'est une contrainte de la base
     * autant qu'une regle metier.
     */
    @Transactional
    public StatutUtilisateur declarer(String acteur, Long utilisateurId, TypeStatut type,
                                      OffsetDateTime debut, OffsetDateTime finPrevue,
                                      String lieu, String commentaire) {
        OffsetDateTime maintenant = OffsetDateTime.now(horloge);
        OffsetDateTime depart = debut != null ? debut : maintenant;

        if (finPrevue != null && finPrevue.isBefore(depart)) {
            throw ExceptionMetier.regleViolee("La fin prevue precede le debut du statut");
        }

        depot.findByUtilisateurIdAndFinReelleIsNull(utilisateurId).ifPresent(precedent -> {
            precedent.terminer(depart);
            depot.save(precedent);
            journal.tracer(acteur, "STATUT_TERMINE_AUTOMATIQUEMENT", "statut_utilisateur",
                    precedent.getId(), precedent.getType().name(), "ferme par un nouveau statut");
        });

        StatutUtilisateur statut = new StatutUtilisateur(utilisateurId, type, depart);
        statut.setFinPrevue(finPrevue);
        statut.setLieu(lieu);
        statut.setCommentaire(commentaire);

        StatutUtilisateur enregistre = depot.save(statut);
        journal.tracer(acteur, "STATUT_DECLARE", "statut_utilisateur", enregistre.getId(),
                null, "%s%s".formatted(type, lieu != null ? " (" + lieu + ")" : ""));
        return enregistre;
    }

    /**
     * Termine un statut. La dette de taches (rattrapages etales sur plusieurs
     * jours) est traitee par le moteur au lot 3 : ici, on se contente de fermer
     * proprement la periode.
     */
    @Transactional
    public StatutUtilisateur terminer(String acteur, Long statutId, OffsetDateTime fin) {
        StatutUtilisateur statut = depot.findById(statutId)
                .orElseThrow(() -> ExceptionMetier.introuvable("Statut", statutId));

        if (!statut.estOuvert()) {
            throw ExceptionMetier.regleViolee("Ce statut est deja termine");
        }

        OffsetDateTime date = fin != null ? fin : OffsetDateTime.now(horloge);
        if (date.isBefore(statut.getDebut())) {
            throw ExceptionMetier.regleViolee("La fin ne peut pas preceder le debut du statut");
        }

        statut.terminer(date);
        journal.tracer(acteur, "STATUT_TERMINE", "statut_utilisateur", statutId,
                statut.getType().name(), "termine le " + date);
        return depot.save(statut);
    }

    /** Effets applicables pour un statut, par categorie de tache. */
    @Transactional(readOnly = true)
    public Map<CategorieTache, EffetStatut> effets(TypeStatut type) {
        return depotRegles.findByTypeStatut(type).stream()
                .collect(Collectors.toMap(RegleStatut::getCategorieTache, RegleStatut::getEffet));
    }

    @Transactional(readOnly = true)
    public EffetStatut effet(TypeStatut type, CategorieTache categorie) {
        return depotRegles.findByTypeStatutAndCategorieTache(type, categorie)
                .map(RegleStatut::getEffet)
                .orElse(EffetStatut.MAINTENIR);
    }
}
