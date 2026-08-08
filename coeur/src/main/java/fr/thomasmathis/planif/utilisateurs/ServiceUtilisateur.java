package fr.thomasmathis.planif.utilisateurs;

import java.util.List;
import java.util.Optional;

import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import fr.thomasmathis.planif.commun.ExceptionMetier;

@Service
public class ServiceUtilisateur {

    private final DepotUtilisateur depot;
    private final PasswordEncoder encodeur;

    public ServiceUtilisateur(DepotUtilisateur depot, PasswordEncoder encodeur) {
        this.depot = depot;
        this.encodeur = encodeur;
    }

    /**
     * Verifie les identifiants.
     *
     * <p>Le hachage est calcule meme quand l'identifiant est inconnu, pour ne pas
     * reveler l'existence d'un compte par le temps de reponse.</p>
     */
    @Transactional(readOnly = true)
    public Optional<Utilisateur> authentifier(String identifiant, String motDePasse) {
        Optional<Utilisateur> trouve = depot.findByIdentifiant(identifiant).filter(Utilisateur::isActif);

        if (trouve.isEmpty()) {
            encodeur.matches(motDePasse, "$2a$12$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
            return Optional.empty();
        }
        return trouve.filter(u -> encodeur.matches(motDePasse, u.getMotDePasseHash()));
    }

    @Transactional(readOnly = true)
    public Optional<Utilisateur> parIdentifiantActif(String identifiant) {
        return depot.findByIdentifiant(identifiant).filter(Utilisateur::isActif);
    }

    @Transactional(readOnly = true)
    public Utilisateur parId(Long id) {
        return depot.findById(id).orElseThrow(() -> ExceptionMetier.introuvable("Utilisateur", id));
    }

    @Transactional(readOnly = true)
    public List<Utilisateur> tous() {
        return depot.findAll();
    }

    @Transactional
    public Utilisateur creer(String nom, String identifiant, String motDePasseEnClair, Role role) {
        if (depot.existsByIdentifiant(identifiant)) {
            throw ExceptionMetier.regleViolee("Identifiant deja utilise : " + identifiant);
        }
        return depot.save(new Utilisateur(nom, identifiant, encodeur.encode(motDePasseEnClair), role));
    }

    @Transactional
    public void changerMotDePasse(Long id, String nouveauMotDePasse) {
        Utilisateur utilisateur = parId(id);
        utilisateur.setMotDePasseHash(encodeur.encode(nouveauMotDePasse));
        depot.save(utilisateur);
    }
}
