package fr.thomasmathis.planif;

import java.util.TimeZone;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

import jakarta.annotation.PostConstruct;

/**
 * Point d'entree du coeur metier.
 *
 * <p>Le monolithe est modulaire : chaque paquet sous {@code fr.thomasmathis.planif}
 * porte un module fonctionnel et ne depend jamais des entites internes d'un autre
 * module, uniquement de ses interfaces exposees (cf. cahier des charges, 4.4).</p>
 */
@SpringBootApplication
@EnableScheduling
public class PlanifApplication {

    public static void main(String[] args) {
        SpringApplication.run(PlanifApplication.class, args);
    }

    /**
     * Tout est stocke et manipule en UTC ; la conversion vers Europe/Paris est
     * faite a l'affichage uniquement (cf. cahier des charges, 10).
     */
    @PostConstruct
    void forcerFuseauJvmEnUtc() {
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"));
    }
}
