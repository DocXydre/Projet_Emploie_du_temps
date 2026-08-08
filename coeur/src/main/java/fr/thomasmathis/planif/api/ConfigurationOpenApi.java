package fr.thomasmathis.planif.api;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.servers.Server;

/**
 * La specification OpenAPI est un livrable au meme titre que le code : c'est le
 * contrat sur lequel s'appuiera l'application Angular (cf. cahier des charges, 1.4).
 */
@Configuration
public class ConfigurationOpenApi {

    @Bean
    public OpenAPI specification(@Value("${planif.version:dev}") String version) {
        return new OpenAPI()
                .info(new Info()
                        .title("API de planification personnelle")
                        .version(version)
                        .description("""
                                Croisement d'emplois du temps heterogenes, planification de taches
                                recurrentes et gestion de stock en flux tendu.

                                Regle de conception : aucune logique metier dans le client. Si un client
                                doit calculer si une tache est en retard, c'est que l'API aurait du le dire.
                                """))
                .addServersItem(new Server().url("/").description("Serveur courant"));
    }
}
