package fr.thomasmathis.planif.contraintes;

import java.time.Duration;
import java.time.OffsetDateTime;

import fr.thomasmathis.planif.sante.EtatSante;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * Une source de contraintes dures et son etat de fraicheur.
 *
 * <p>Le moteur ne doit jamais planifier sur des donnees perimees sans le
 * signaler : un planning silencieusement faux est pire que pas de planning
 * (cf. 7.1 A.1).</p>
 */
@Entity
@Table(name = "source_contrainte")
public class SourceContrainte {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true)
    private String code;

    @Column(nullable = false)
    private String libelle;

    @Enumerated(EnumType.STRING)
    @Column(name = "type_collecte", nullable = false)
    private TypeCollecte typeCollecte;

    @Column(name = "derniere_collecte_ok")
    private OffsetDateTime derniereCollecteOk;

    @Column(name = "derniere_collecte_tentee")
    private OffsetDateTime derniereCollecteTentee;

    @Enumerated(EnumType.STRING)
    @Column(name = "etat_sante", nullable = false)
    private EtatSante etatSante = EtatSante.OK;

    @Column(name = "ttl_fraicheur_heures", nullable = false)
    private int ttlFraicheurHeures = 24;

    @Column
    private String configuration;

    @Column(nullable = false)
    private boolean active = true;

    protected SourceContrainte() {
        // requis par JPA
    }

    /**
     * Recalcule l'etat a partir de la fraicheur : {@code DEGRADE} des le TTL
     * depasse, {@code MORT} au dela du double. Une source manuelle ou inactive
     * ne perime pas.
     */
    public EtatSante evaluerFraicheur(OffsetDateTime maintenant) {
        if (!active || typeCollecte == TypeCollecte.MANUELLE) {
            return EtatSante.OK;
        }
        if (derniereCollecteOk == null) {
            return EtatSante.MORT;
        }
        Duration age = Duration.between(derniereCollecteOk, maintenant);
        long ttl = ttlFraicheurHeures;
        if (age.toHours() >= ttl * 2) {
            return EtatSante.MORT;
        }
        return age.toHours() >= ttl ? EtatSante.DEGRADE : EtatSante.OK;
    }

    public Long getId() {
        return id;
    }

    public String getCode() {
        return code;
    }

    public String getLibelle() {
        return libelle;
    }

    public TypeCollecte getTypeCollecte() {
        return typeCollecte;
    }

    public OffsetDateTime getDerniereCollecteOk() {
        return derniereCollecteOk;
    }

    public void setDerniereCollecteOk(OffsetDateTime derniereCollecteOk) {
        this.derniereCollecteOk = derniereCollecteOk;
    }

    public OffsetDateTime getDerniereCollecteTentee() {
        return derniereCollecteTentee;
    }

    public void setDerniereCollecteTentee(OffsetDateTime derniereCollecteTentee) {
        this.derniereCollecteTentee = derniereCollecteTentee;
    }

    public EtatSante getEtatSante() {
        return etatSante;
    }

    public void setEtatSante(EtatSante etatSante) {
        this.etatSante = etatSante;
    }

    public int getTtlFraicheurHeures() {
        return ttlFraicheurHeures;
    }

    public void setTtlFraicheurHeures(int ttlFraicheurHeures) {
        this.ttlFraicheurHeures = ttlFraicheurHeures;
    }

    public String getConfiguration() {
        return configuration;
    }

    public void setConfiguration(String configuration) {
        this.configuration = configuration;
    }

    public boolean isActive() {
        return active;
    }

    public void setActive(boolean active) {
        this.active = active;
    }
}
