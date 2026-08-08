package fr.thomasmathis.planif.taches;

import java.time.LocalTime;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * Le modele recurrent d'une tache : « passer l'aspirateur tous les 2 a 3 jours ».
 * Ne porte aucune date : ce sont les occurrences qui en portent.
 */
@Entity
@Table(name = "definition_tache")
public class DefinitionTache {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true)
    private String code;

    @Column(nullable = false)
    private String libelle;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private CategorieTache categorie;

    /** Niveau P0 a P5. Le nombre le plus bas gagne toujours (6.3). */
    @Column(nullable = false)
    private short priorite;

    @Column(name = "duree_minutes", nullable = false)
    private int dureeMinutes;

    @Column(name = "intervalle_min_jours", nullable = false)
    private int intervalleMinJours;

    @Column(name = "intervalle_max_jours", nullable = false)
    private int intervalleMaxJours;

    @Column(name = "assignation_par_defaut")
    private Long assignationParDefaut;

    /** FALSE pour la litiere et la lessive de travail : dues meme en statut MALADE. */
    @Column(nullable = false)
    private boolean gelable = true;

    @Column(name = "fenetre_horaire_debut")
    private LocalTime fenetreHoraireDebut;

    @Column(name = "fenetre_horaire_fin")
    private LocalTime fenetreHoraireFin;

    @Column(nullable = false)
    private boolean active = true;

    protected DefinitionTache() {
        // requis par JPA
    }

    public DefinitionTache(String code, String libelle, CategorieTache categorie, short priorite,
                           int dureeMinutes, int intervalleMinJours, int intervalleMaxJours) {
        this.code = code;
        this.libelle = libelle;
        this.categorie = categorie;
        this.priorite = priorite;
        this.dureeMinutes = dureeMinutes;
        this.intervalleMinJours = intervalleMinJours;
        this.intervalleMaxJours = intervalleMaxJours;
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

    public void setLibelle(String libelle) {
        this.libelle = libelle;
    }

    public CategorieTache getCategorie() {
        return categorie;
    }

    public void setCategorie(CategorieTache categorie) {
        this.categorie = categorie;
    }

    public short getPriorite() {
        return priorite;
    }

    public void setPriorite(short priorite) {
        this.priorite = priorite;
    }

    public int getDureeMinutes() {
        return dureeMinutes;
    }

    public void setDureeMinutes(int dureeMinutes) {
        this.dureeMinutes = dureeMinutes;
    }

    public int getIntervalleMinJours() {
        return intervalleMinJours;
    }

    public void setIntervalleMinJours(int intervalleMinJours) {
        this.intervalleMinJours = intervalleMinJours;
    }

    public int getIntervalleMaxJours() {
        return intervalleMaxJours;
    }

    public void setIntervalleMaxJours(int intervalleMaxJours) {
        this.intervalleMaxJours = intervalleMaxJours;
    }

    public Long getAssignationParDefaut() {
        return assignationParDefaut;
    }

    public void setAssignationParDefaut(Long assignationParDefaut) {
        this.assignationParDefaut = assignationParDefaut;
    }

    public boolean isGelable() {
        return gelable;
    }

    public void setGelable(boolean gelable) {
        this.gelable = gelable;
    }

    public LocalTime getFenetreHoraireDebut() {
        return fenetreHoraireDebut;
    }

    public void setFenetreHoraireDebut(LocalTime fenetreHoraireDebut) {
        this.fenetreHoraireDebut = fenetreHoraireDebut;
    }

    public LocalTime getFenetreHoraireFin() {
        return fenetreHoraireFin;
    }

    public void setFenetreHoraireFin(LocalTime fenetreHoraireFin) {
        this.fenetreHoraireFin = fenetreHoraireFin;
    }

    public boolean isActive() {
        return active;
    }

    public void setActive(boolean active) {
        this.active = active;
    }
}
