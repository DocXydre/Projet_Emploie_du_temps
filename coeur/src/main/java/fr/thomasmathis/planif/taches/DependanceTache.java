package fr.thomasmathis.planif.taches;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** Exemple : POUSSIERE declenche ASPIRATEUR dans les 24 heures (7.4 D.4). */
@Entity
@Table(name = "dependance_tache")
public class DependanceTache {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "definition_source_id", nullable = false)
    private Long definitionSourceId;

    @Column(name = "definition_cible_id", nullable = false)
    private Long definitionCibleId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private TypeDependance type = TypeDependance.DECLENCHE_APRES;

    @Column(name = "delai_max_heures", nullable = false)
    private int delaiMaxHeures;

    protected DependanceTache() {
        // requis par JPA
    }

    public DependanceTache(Long definitionSourceId, Long definitionCibleId, int delaiMaxHeures) {
        this.definitionSourceId = definitionSourceId;
        this.definitionCibleId = definitionCibleId;
        this.delaiMaxHeures = delaiMaxHeures;
    }

    public Long getId() {
        return id;
    }

    public Long getDefinitionSourceId() {
        return definitionSourceId;
    }

    public Long getDefinitionCibleId() {
        return definitionCibleId;
    }

    public TypeDependance getType() {
        return type;
    }

    public int getDelaiMaxHeures() {
        return delaiMaxHeures;
    }

    public void setDelaiMaxHeures(int delaiMaxHeures) {
        this.delaiMaxHeures = delaiMaxHeures;
    }
}
