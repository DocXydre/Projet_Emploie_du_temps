package fr.thomasmathis.planif.utilisateurs;

import java.time.OffsetDateTime;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

@Entity
@Table(name = "utilisateur")
public class Utilisateur {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false)
    private String nom;

    @Column(nullable = false, unique = true)
    private String identifiant;

    @Column(name = "mot_de_passe_hash", nullable = false)
    private String motDePasseHash;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private Role role;

    @Column(nullable = false)
    private String fuseau = "Europe/Paris";

    @Column(name = "canal_notification")
    private String canalNotification;

    @Column(nullable = false)
    private boolean actif = true;

    @Column(name = "cree_le", nullable = false, insertable = false, updatable = false)
    private OffsetDateTime creeLe;

    protected Utilisateur() {
        // requis par JPA
    }

    public Utilisateur(String nom, String identifiant, String motDePasseHash, Role role) {
        this.nom = nom;
        this.identifiant = identifiant;
        this.motDePasseHash = motDePasseHash;
        this.role = role;
    }

    public boolean estAdministrateur() {
        return role == Role.ADMINISTRATEUR;
    }

    public Long getId() {
        return id;
    }

    public String getNom() {
        return nom;
    }

    public void setNom(String nom) {
        this.nom = nom;
    }

    public String getIdentifiant() {
        return identifiant;
    }

    public String getMotDePasseHash() {
        return motDePasseHash;
    }

    public void setMotDePasseHash(String motDePasseHash) {
        this.motDePasseHash = motDePasseHash;
    }

    public Role getRole() {
        return role;
    }

    public void setRole(Role role) {
        this.role = role;
    }

    public String getFuseau() {
        return fuseau;
    }

    public void setFuseau(String fuseau) {
        this.fuseau = fuseau;
    }

    public String getCanalNotification() {
        return canalNotification;
    }

    public void setCanalNotification(String canalNotification) {
        this.canalNotification = canalNotification;
    }

    public boolean isActif() {
        return actif;
    }

    public void setActif(boolean actif) {
        this.actif = actif;
    }

    public OffsetDateTime getCreeLe() {
        return creeLe;
    }
}
