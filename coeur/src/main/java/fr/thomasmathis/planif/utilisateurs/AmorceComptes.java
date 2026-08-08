package fr.thomasmathis.planif.utilisateurs;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

/**
 * Cree les deux comptes au premier demarrage, a partir de variables
 * d'environnement.
 *
 * <p>Les mots de passe ne sont jamais dans une migration ni dans le depot
 * (cf. cahier des charges, 9). Si les variables sont absentes, l'amorce ne fait
 * rien et le journal l'indique clairement : mieux vaut une API sans compte
 * qu'une API avec un mot de passe par defaut.</p>
 */
@Component
public class AmorceComptes implements ApplicationRunner {

    private static final Logger LOG = LoggerFactory.getLogger(AmorceComptes.class);

    private final ServiceUtilisateur service;
    private final DepotUtilisateur depot;
    private final String identifiantAdmin;
    private final String motDePasseAdmin;
    private final String identifiantStandard;
    private final String motDePasseStandard;

    public AmorceComptes(ServiceUtilisateur service,
                         DepotUtilisateur depot,
                         @Value("${planif.comptes.admin.identifiant:thomas}") String identifiantAdmin,
                         @Value("${planif.comptes.admin.mot-de-passe:}") String motDePasseAdmin,
                         @Value("${planif.comptes.standard.identifiant:lorette}") String identifiantStandard,
                         @Value("${planif.comptes.standard.mot-de-passe:}") String motDePasseStandard) {
        this.service = service;
        this.depot = depot;
        this.identifiantAdmin = identifiantAdmin;
        this.motDePasseAdmin = motDePasseAdmin;
        this.identifiantStandard = identifiantStandard;
        this.motDePasseStandard = motDePasseStandard;
    }

    @Override
    public void run(ApplicationArguments arguments) {
        creerSiAbsent(identifiantAdmin, motDePasseAdmin, "Thomas", Role.ADMINISTRATEUR);
        creerSiAbsent(identifiantStandard, motDePasseStandard, "Lorette", Role.STANDARD);
    }

    private void creerSiAbsent(String identifiant, String motDePasse, String nom, Role role) {
        if (depot.existsByIdentifiant(identifiant)) {
            return;
        }
        if (motDePasse == null || motDePasse.isBlank()) {
            LOG.warn("Compte '{}' non cree : mot de passe absent. "
                    + "Renseigner PLANIF_COMPTES_{}_MOT_DE_PASSE puis redemarrer.",
                    identifiant, role == Role.ADMINISTRATEUR ? "ADMIN" : "STANDARD");
            return;
        }
        service.creer(nom, identifiant, motDePasse, role);
        LOG.info("Compte '{}' cree avec le role {}", identifiant, role);
    }
}
